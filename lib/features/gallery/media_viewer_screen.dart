import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/models/vault_media.dart';
import '../../data/services/vault_controller.dart';
import '../../data/services/vault_providers.dart';

class MediaViewerScreen extends ConsumerStatefulWidget {
  final int initialIndex;
  final List<String> items;
  final bool isVideoMode;

  const MediaViewerScreen({
    super.key,
    this.initialIndex = 0,
    this.items = const [],
    this.isVideoMode = false,
  });

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  static const Set<String> _allowedVideoExtensions = {
    'mp4',
    'mkv',
    'mov',
    'webm',
    '3gp',
    'm4v',
    'avi',
    'ts',
  };

  PageController? _pageController;
  List<VaultMedia> _mediaList = [];
  int _currentIndex = 0;
  bool _initialized = false;
  bool _isZoomed = false;
  TapDownDetails? _doubleTapDetails;

  final Map<String, Uint8List> _bytesCache = {};
  final Set<String> _loadingIds = {};
  final Map<String, String> _errorById = {};
  final Map<String, TransformationController> _zoomControllers = {};

  final Queue<VaultMedia> _prefetchQueue = Queue<VaultMedia>();
  Set<String> _activeWindowIds = {};
  bool _isDrainingPrefetch = false;

  String? _activeVideoMediaId;
  VideoPlayerController? _videoController;
  File? _tempVideoFile;
  bool _videoInitializing = false;
  int _videoLoadToken = 0;

  static bool _isVideoMedia(VaultMedia media) =>
      VaultController.isVideoFile(media);

  static String _safeVideoExtension(String fileName) {
    var cleaned = fileName.trim().toLowerCase();
    for (final wrapperExt in const ['.enc', '.vaul', '.vgz1', '.tmp']) {
      if (cleaned.endsWith(wrapperExt)) {
        cleaned = cleaned.substring(0, cleaned.length - wrapperExt.length);
      }
    }
    final dotIndex = cleaned.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < cleaned.length - 1) {
      final candidate = cleaned.substring(dotIndex + 1);
      if (_allowedVideoExtensions.contains(candidate)) {
        return candidate;
      }
    }
    return 'mp4';
  }

  static String _safeFileId(String id) {
    final sanitized = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return sanitized.isEmpty ? 'media' : sanitized;
  }

  static Future<void> _safeDeleteFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _cleanupOrphanedTempVideos() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final activePath = _tempVideoFile?.path;
      await for (final entity in tempDir.list()) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('vault_play_') && entity.path != activePath) {
            await _safeDeleteFile(entity);
          }
        }
      }
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    unawaited(_cleanupOrphanedTempVideos());

    final arg = ModalRoute.of(context)?.settings.arguments;
    List<VaultMedia> resolvedList = [];
    int resolvedIndex = widget.initialIndex;

    if (arg is Map) {
      final rawItems = arg['items'];
      if (rawItems is List<VaultMedia>) {
        resolvedList = List<VaultMedia>.from(rawItems);
      } else if (rawItems is List) {
        resolvedList = rawItems.whereType<VaultMedia>().toList();
      }
      final rawIdx = arg['initialIndex'];
      if (rawIdx is int) {
        resolvedIndex = rawIdx;
      }
    } else if (arg is VaultMedia) {
      final controller = ref.read(vaultControllerProvider);
      final all = controller.localDbService.isOpen
          ? controller.localDbService.getAllMedia()
          : controller.mediaItems;
      final foundIdx = all.indexWhere((m) => m.id == arg.id);
      if (foundIdx >= 0) {
        resolvedList = List<VaultMedia>.from(all);
        resolvedIndex = foundIdx;
      } else {
        resolvedList = [arg];
        resolvedIndex = 0;
      }
    }

    if (resolvedList.isEmpty) {
      resolvedIndex = 0;
    } else {
      resolvedIndex = resolvedIndex.clamp(0, resolvedList.length - 1);
    }

    _mediaList = resolvedList;
    _currentIndex = resolvedIndex;
    _pageController = PageController(initialPage: _currentIndex);

    if (_mediaList.isNotEmpty) {
      _hydrateWindowFromRamCache(_currentIndex);
      unawaited(_openIndex(_currentIndex));
    }
  }

  @override
  void dispose() {
    _videoLoadToken++;
    _prefetchQueue.clear();
    _activeWindowIds.clear();
    _disposeActiveVideo();
    _pageController?.dispose();
    for (final ctrl in _zoomControllers.values) {
      ctrl.dispose();
    }
    _zoomControllers.clear();
    _bytesCache.clear();
    super.dispose();
  }

  /// Synchronously pulls already-decrypted neighbors [-2..+2] from DownloadService RAM
  /// so swiping renders them in 0ms without a loading spinner flash.
  void _hydrateWindowFromRamCache(int centerIndex) {
    final controller = ref.read(vaultControllerProvider);
    for (int i = centerIndex - 2; i <= centerIndex + 2; i++) {
      if (i < 0 || i >= _mediaList.length) continue;
      final item = _mediaList[i];
      if (_isVideoMedia(item) || _bytesCache.containsKey(item.id)) continue;
      final ramBytes = controller.downloadService.getCachedBytes(item.id);
      if (ramBytes != null && ramBytes.isNotEmpty) {
        _bytesCache[item.id] = ramBytes;
      }
    }
  }

  TransformationController _zoomControllerFor(String id) {
    return _zoomControllers.putIfAbsent(id, () {
      final ctrl = TransformationController();
      ctrl.addListener(() {
        if (!mounted || _mediaList.isEmpty) return;
        if (_mediaList[_currentIndex].id != id) return;
        final zoomedNow = ctrl.value.getMaxScaleOnAxis() > 1.05;
        if (zoomedNow != _isZoomed) {
          setState(() => _isZoomed = zoomedNow);
        }
      });
      return ctrl;
    });
  }

  void _handleDoubleTapZoom(String mediaId) {
    final ctrl = _zoomControllerFor(mediaId);
    final currentScale = ctrl.value.getMaxScaleOnAxis();
    if (currentScale > 1.05) {
      ctrl.value = Matrix4.identity();
    } else {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      const scale = 2.5;
      final matrix = Matrix4.diagonal3Values(scale, scale, 1.0);
      matrix.setTranslationRaw(
        -pos.dx * (scale - 1),
        -pos.dy * (scale - 1),
        0.0,
      );
      ctrl.value = matrix;
    }
  }

  void _disposeActiveVideo() {
    final vc = _videoController;
    final temp = _tempVideoFile;
    _videoController = null;
    _tempVideoFile = null;
    _activeVideoMediaId = null;
    _videoInitializing = false;

    if (vc != null) {
      unawaited(
        vc.dispose().catchError((_) {}).whenComplete(() => _safeDeleteFile(temp)),
      );
    } else if (temp != null) {
      unawaited(_safeDeleteFile(temp));
    }
  }

  Future<void> _openIndex(int index) async {
    if (index < 0 || index >= _mediaList.length) return;
    final target = _mediaList[index];
    await _loadForegroundMedia(target);
    if (mounted && _isCurrentMedia(target.id)) {
      _slideWindowAround(index);
    }
  }

  Future<void> _loadForegroundMedia(VaultMedia media) async {
    if (_isVideoMedia(media)) {
      if (_isCurrentMedia(media.id)) {
        await _loadAndPlayVideo(media);
      }
      return;
    }

    if (_bytesCache.containsKey(media.id)) return;

    final controller = ref.read(vaultControllerProvider);
    final ramCached = controller.downloadService.getCachedBytes(media.id);
    if (ramCached != null && ramCached.isNotEmpty) {
      if (mounted) {
        setState(() {
          _errorById.remove(media.id);
          _bytesCache[media.id] = ramCached;
        });
      }
      return;
    }

    if (_loadingIds.contains(media.id)) return;
    _loadingIds.add(media.id);
    if (mounted) {
      setState(() => _errorById.remove(media.id));
    }

    try {
      final bytes = await controller.loadDecryptedBytes(media);
      if (!mounted) return;
      setState(() {
        _loadingIds.remove(media.id);
        _errorById.remove(media.id);
        _bytesCache[media.id] = bytes;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingIds.remove(media.id);
        _errorById[media.id] = e.toString();
      });
    }
  }

  /// Slides the [-2, -1, current, +1, +2] background decrypt window around [centerIndex].
  void _slideWindowAround(int centerIndex) {
    if (_mediaList.isEmpty) return;

    final newActiveWindow = <String>{};
    for (int i = centerIndex - 2; i <= centerIndex + 2; i++) {
      if (i >= 0 && i < _mediaList.length) {
        newActiveWindow.add(_mediaList[i].id);
      }
    }
    _activeWindowIds = newActiveWindow;

    final keepIds = <String>{};
    for (int i = centerIndex - 3; i <= centerIndex + 3; i++) {
      if (i >= 0 && i < _mediaList.length) {
        keepIds.add(_mediaList[i].id);
      }
    }

    _bytesCache.removeWhere((id, _) => !keepIds.contains(id));

    for (final entry in _zoomControllers.entries.toList()) {
      if (!keepIds.contains(entry.key)) {
        entry.value.dispose();
        _zoomControllers.remove(entry.key);
      } else if (entry.key != _mediaList[centerIndex].id) {
        entry.value.value = Matrix4.identity();
      }
    }

    // Priority order: +1, -1, +2, -2
    _prefetchQueue.clear();
    final offsets = <int>[1, -1, 2, -2];
    for (final offset in offsets) {
      final idx = centerIndex + offset;
      if (idx < 0 || idx >= _mediaList.length) continue;
      final item = _mediaList[idx];
      if (_isVideoMedia(item)) continue;
      if (_bytesCache.containsKey(item.id) || _loadingIds.contains(item.id)) {
        continue;
      }
      _prefetchQueue.add(item);
    }

    if (!_isDrainingPrefetch && _prefetchQueue.isNotEmpty) {
      unawaited(_drainPrefetchQueue());
    }
  }

  Future<void> _drainPrefetchQueue() async {
    if (_isDrainingPrefetch) return;
    _isDrainingPrefetch = true;
    final controller = ref.read(vaultControllerProvider);

    try {
      while (_prefetchQueue.isNotEmpty && mounted) {
        final next = _prefetchQueue.removeFirst();
        if (!_activeWindowIds.contains(next.id)) continue;
        if (_bytesCache.containsKey(next.id) || _loadingIds.contains(next.id)) {
          continue;
        }

        _loadingIds.add(next.id);
        try {
          final bytes = await controller.prefetchDecryptedBytes(next);
          if (!mounted) break;
          if (bytes != null &&
              bytes.isNotEmpty &&
              _activeWindowIds.contains(next.id)) {
            setState(() {
              _bytesCache[next.id] = bytes;
            });
          }
        } finally {
          _loadingIds.remove(next.id);
        }
      }
    } finally {
      _isDrainingPrefetch = false;
    }
  }

  Future<void> _loadAndPlayVideo(VaultMedia media) async {
    if (_activeVideoMediaId == media.id &&
        (_videoController != null || _videoInitializing)) {
      return;
    }

    final loadToken = ++_videoLoadToken;
    _disposeActiveVideo();
    _activeVideoMediaId = media.id;
    _videoInitializing = true;
    if (mounted) {
      setState(() {
        _errorById.remove(media.id);
      });
    }

    File? targetFile;
    VideoPlayerController? vc;
    try {
      final tempDir = await getTemporaryDirectory();
      final ext = _safeVideoExtension(media.fileName);
      final safeId = _safeFileId(media.id);
      targetFile = File(
        '${tempDir.path}${Platform.pathSeparator}vault_play_${safeId}_$loadToken.$ext',
      );
      await _safeDeleteFile(targetFile);

      final controller = ref.read(vaultControllerProvider);
      await controller.downloadVideoToFile(media, targetFile);

      if (loadToken != _videoLoadToken ||
          !mounted ||
          !_isCurrentMedia(media.id)) {
        await _safeDeleteFile(targetFile);
        return;
      }

      if (!await targetFile.exists() || await targetFile.length() == 0) {
        throw StateError('Decrypted video file is empty.');
      }

      vc = VideoPlayerController.file(targetFile);
      await vc.initialize();

      if (loadToken != _videoLoadToken ||
          !mounted ||
          !_isCurrentMedia(media.id)) {
        await vc.dispose();
        await _safeDeleteFile(targetFile);
        return;
      }

      await vc.setLooping(true);
      await vc.play();

      _tempVideoFile = targetFile;
      setState(() {
        _videoController = vc;
        _videoInitializing = false;
      });
    } catch (e) {
      if (vc != null) {
        try {
          await vc.dispose();
        } catch (_) {}
      }
      await _safeDeleteFile(targetFile);
      if (!mounted || loadToken != _videoLoadToken) return;
      setState(() {
        _videoInitializing = false;
        _activeVideoMediaId = null;
        _errorById[media.id] = 'Video playback error: $e';
      });
    }
  }

  bool _isCurrentMedia(String id) {
    return _mediaList.isNotEmpty &&
        _currentIndex >= 0 &&
        _currentIndex < _mediaList.length &&
        _mediaList[_currentIndex].id == id;
  }

  void _onPageChanged(int newIndex) {
    if (newIndex < 0 || newIndex >= _mediaList.length) return;

    if (_activeVideoMediaId != null &&
        _activeVideoMediaId != _mediaList[newIndex].id) {
      _videoLoadToken++;
      _disposeActiveVideo();
    }

    _hydrateWindowFromRamCache(newIndex);
    setState(() {
      _currentIndex = newIndex;
      _isZoomed = false;
    });

    unawaited(_openIndex(newIndex));
  }

  Future<void> _toggleFavoriteCurrent() async {
    if (_mediaList.isEmpty) return;
    final media = _mediaList[_currentIndex];
    final controller = ref.read(vaultControllerProvider);
    await controller.toggleFavorite(media);
    if (!mounted) return;
    setState(() {
      _mediaList[_currentIndex] = media.copyWith(isFavorite: !media.isFavorite);
    });
  }

  Future<void> _deleteCurrentMedia() async {
    if (_mediaList.isEmpty) return;
    final media = _mediaList[_currentIndex];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161F),
        title: const Text('Delete from Vault?'),
        content: Text(
          'Remove "${media.fileName}" from your local vault list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;
    await ref.read(vaultControllerProvider).deleteMediaRecord(media.id);
    if (!mounted) return;

    if (_activeVideoMediaId == media.id) {
      _videoLoadToken++;
      _disposeActiveVideo();
    }
    _bytesCache.remove(media.id);
    _errorById.remove(media.id);
    _zoomControllers.remove(media.id)?.dispose();

    _mediaList.removeAt(_currentIndex);
    if (_mediaList.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final nextIndex = _currentIndex.clamp(0, _mediaList.length - 1);
    _hydrateWindowFromRamCache(nextIndex);
    setState(() {
      _currentIndex = nextIndex;
      _isZoomed = false;
    });
    _pageController?.jumpToPage(nextIndex);
    unawaited(_openIndex(nextIndex));
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  Widget _buildVideoPage(VaultMedia media, double progress) {
    if (_activeVideoMediaId != media.id || _videoController == null) {
      if (_isCurrentMedia(media.id) &&
          !_videoInitializing &&
          !_errorById.containsKey(media.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isCurrentMedia(media.id)) {
            unawaited(_loadAndPlayVideo(media));
          }
        });
      }
      return Center(
        child: GlassCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.cyanAccent),
              const SizedBox(height: 16),
              Text(
                'Streaming & decrypting video... ${(progress * 100).toInt()}%',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    final vc = _videoController!;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio:
                  vc.value.aspectRatio > 0 ? vc.value.aspectRatio : 16 / 9,
              child: VideoPlayer(vc),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: GlassCard(
            borderRadius: 20,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoProgressIndicator(
                  vc,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.cyanAccent,
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.white12,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: vc,
                  builder: (context, val, _) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(val.position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          val.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.cyanAccent,
                          size: 38,
                        ),
                        onPressed: () {
                          if (val.isPlaying) {
                            vc.pause();
                          } else {
                            vc.play();
                          }
                        },
                      ),
                      Text(
                        _formatDuration(val.duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPageContent(VaultMedia media, double progress) {
    final err = _errorById[media.id];
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassCard(
            borderRadius: 24,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 44,
                ),
                const SizedBox(height: 12),
                Text(
                  'Decryption failed:\n$err',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () => _loadForegroundMedia(media),
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: Colors.cyanAccent,
                      ),
                      label: const Text(
                        'Retry',
                        style: TextStyle(color: Colors.cyanAccent),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _deleteCurrentMedia,
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                      ),
                      label: const Text(
                        'Remove',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isVideoMedia(media)) {
      return _buildVideoPage(media, progress);
    }

    final bytes = _bytesCache[media.id];
    if (bytes == null) {
      return Center(
        child: GlassCard(
          borderRadius: 24,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.cyanAccent),
              const SizedBox(height: 16),
              Text(
                'Decrypting in RAM... ${(progress * 100).toInt()}%',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (bytes.isEmpty) {
      return const Center(
        child: Text(
          'Empty media data.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return SizedBox.expand(
      child: GestureDetector(
        onDoubleTapDown: (details) => _doubleTapDetails = details,
        onDoubleTap: () => _handleDoubleTapZoom(media.id),
        child: InteractiveViewer(
          transformationController: _zoomControllerFor(media.id),
          minScale: 1.0,
          maxScale: 5.0,
          clipBehavior: Clip.hardEdge,
          child: SizedBox.expand(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final currentMedia =
        _mediaList.isNotEmpty ? _mediaList[_currentIndex] : null;

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.35),
          elevation: 0,
          title: currentMedia == null
              ? const Text('Media Viewer')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentMedia.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    Text(
                      '${_currentIndex + 1} / ${_mediaList.length}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
          actions: [
            if (currentMedia != null) ...[
              IconButton(
                icon: Icon(
                  currentMedia.isFavorite
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: currentMedia.isFavorite
                      ? Colors.pinkAccent
                      : Colors.white,
                ),
                onPressed: _toggleFavoriteCurrent,
              ),
              IconButton(
                icon:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: _deleteCurrentMedia,
              ),
            ],
          ],
        ),
        body: currentMedia == null || _pageController == null
            ? const Center(
                child: Text(
                  'No media selected.',
                  style: TextStyle(color: Colors.white70),
                ),
              )
            : PageView.builder(
                controller: _pageController,
                physics: _isZoomed
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                itemCount: _mediaList.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  final item = _mediaList[index];
                  return KeyedSubtree(
                    key: ValueKey(item.id),
                    child: _buildPageContent(item, controller.operationProgress),
                  );
                },
              ),
      ),
    );
  }
}