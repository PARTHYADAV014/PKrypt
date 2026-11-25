import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/widgets/floating_widget.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_icon_button.dart';
import '../../core/widgets/glow_background.dart';
import '../../data/models/face_cluster.dart';
import '../../data/models/vault_media.dart';
import '../../data/services/upload_service.dart';
import '../../data/services/vault_controller.dart';
import '../../data/services/vault_providers.dart';
import 'person_detail_screen.dart';
import 'widgets/person_tile.dart';

enum _GalleryTab { all, photos, videos, people, favorites }

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final _picker = ImagePicker();
  final _searchController = TextEditingController();

  _GalleryTab _activeTab = _GalleryTab.all;
  String _searchQuery = '';
  bool _isSearching = false;
  String? _statusBanner;
  bool _isBannerError = false;

  int _queueTotal = 0;
  int _queueDone = 0;
  String? _currentUploadingName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static bool _isVideoMedia(VaultMedia media) =>
      VaultController.isVideoFile(media);

  static String _inferMimeType(XFile file, {bool forceVideo = false}) {
    if (file.mimeType != null && file.mimeType!.isNotEmpty) {
      return file.mimeType!;
    }
    final lower = file.name.toLowerCase();
    if (forceVideo || lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.3gp')) return 'video/3gpp';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  void _showBanner(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusBanner = message;
      _isBannerError = isError;
    });
  }

  Future<void> _buildMissingPreviews() async {
    final controller = ref.read(vaultControllerProvider);
    if (!controller.isTelegramReady) {
      _showBanner(
        'Connect Telegram first to build encrypted previews.',
        isError: true,
      );
      return;
    }
    _showBanner('Building encrypted previews in background...');
    final count = await controller.buildMissingThumbnails();
    if (!mounted) return;
    if (count > 0) {
      _showBanner('Generated $count encrypted photo preview(s)!');
    } else {
      _showBanner('All photo previews are already up to date.');
    }
  }

  Future<void> _scanFacesOffline({bool forceRescan = false}) async {
    final controller = ref.read(vaultControllerProvider);
    _showBanner(
      forceRescan
          ? 'Re-scanning all photos offline on device...'
          : 'Scanning faces 100% offline on device...',
    );
    final count = await controller.scanFacesForUnscannedMedia(
      forceRescan: forceRescan,
    );
    controller.refreshVaultData();
    if (!mounted) return;

    final peopleCount = controller.faceClusters.length;
    final scanErr = controller.lastFaceScanError;

    if (scanErr != null && peopleCount == 0) {
      _showBanner('Face scan error: $scanErr', isError: true);
    } else if (count > 0 && peopleCount > 0) {
      _showBanner(
        'Scanned $count photo(s) — $peopleCount person group(s) ready!',
      );
    } else if (count > 0) {
      _showBanner(
        'Scanned $count photo(s), but no clear faces detected.',
      );
    } else if (peopleCount > 0) {
      _showBanner('$peopleCount person group(s) ready.');
    } else {
      _showBanner('No photos available to scan yet.');
    }
  }

  Future<void> _openUploadPickerSheet() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF141526).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const Text(
                    'Encrypt & Upload to Vault',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.cyanAccent,
                    ),
                    title: const Text(
                      'Upload Photos',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Select one or multiple photos',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    onTap: () => Navigator.of(ctx).pop('photos'),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.videocam_outlined,
                      color: Colors.purpleAccent,
                    ),
                    title: const Text(
                      'Upload Video',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Streams in 10 MB encrypted chunks (large video safe)',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    onTap: () => Navigator.of(ctx).pop('video'),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.perm_media_outlined,
                      color: Colors.pinkAccent,
                    ),
                    title: const Text(
                      'Upload Photos & Videos',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Pick mixed photos and videos together',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    onTap: () => Navigator.of(ctx).pop('mixed'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (choice == null || !mounted) return;

    List<XFile> pickedFiles = const [];
    bool forceVideo = false;

    if (choice == 'photos') {
      pickedFiles = await _picker.pickMultiImage();
    } else if (choice == 'video') {
      final video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video != null) {
        pickedFiles = [video];
        forceVideo = true;
      }
    } else if (choice == 'mixed') {
      pickedFiles = await _picker.pickMultipleMedia();
    }

    if (pickedFiles.isEmpty || !mounted) return;
    await _uploadFiles(pickedFiles, forceVideo: forceVideo);
  }

  Future<void> _uploadFiles(
    List<XFile> pickedList, {
    bool forceVideo = false,
  }) async {
    final controller = ref.read(vaultControllerProvider);
    if (!controller.isDecoyMode) {
      if (!controller.isTelegramReady) {
        _showBanner(
          'Telegram is not connected. Open Settings -> Telegram Cloud first.',
          isError: true,
        );
        return;
      }
      if (controller.primaryChannel == null) {
        _showBanner(
          'Primary Vault Channel is not set. Open Settings -> Vault Channels.',
          isError: true,
        );
        return;
      }
    }

    setState(() {
      _statusBanner = null;
      _queueTotal = pickedList.length;
      _queueDone = 0;
    });

    int uploadedCount = 0;
    int skippedDuplicates = 0;
    int failedCount = 0;
    String? firstError;

    for (final picked in pickedList) {
      if (!mounted) break;
      setState(() => _currentUploadingName = picked.name);
      try {
        final mimeType = _inferMimeType(picked, forceVideo: forceVideo);
        final isVideo = mimeType.startsWith('video/');
        final album = isVideo ? 'Videos' : 'Camera';

        if (picked.path.isNotEmpty) {
          await controller.uploadMediaFile(
            filePath: picked.path,
            fileName: picked.name,
            mimeType: mimeType,
            album: album,
          );
        } else {
          final bytes = await picked.readAsBytes();
          await controller.uploadPhoto(
            plainBytes: bytes,
            fileName: picked.name,
            mimeType: mimeType,
            album: album,
          );
        }
        uploadedCount++;
      } on DuplicateMediaException {
        skippedDuplicates++;
      } catch (e) {
        failedCount++;
        firstError ??= e.toString();
      }
      if (!mounted) break;
      setState(() => _queueDone++);
    }

    if (!mounted) return;
    setState(() {
      _queueTotal = 0;
      _queueDone = 0;
      _currentUploadingName = null;
    });

    if (failedCount == 0) {
      if (skippedDuplicates > 0 && uploadedCount == 0) {
        _showBanner('$skippedDuplicates duplicate item(s) already in vault.');
      } else if (skippedDuplicates > 0) {
        _showBanner(
          '$uploadedCount encrypted & uploaded ($skippedDuplicates duplicate skipped).',
        );
      } else {
        _showBanner('$uploadedCount item(s) encrypted & uploaded!');
      }
    } else {
      final dupText =
          skippedDuplicates > 0 ? ', $skippedDuplicates skipped' : '';
      _showBanner(
        '$uploadedCount uploaded$dupText, $failedCount failed: ${firstError ?? "Upload error"}',
        isError: true,
      );
    }
  }

  Future<void> _lockNow() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await ref.read(vaultControllerProvider).lockVault();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/unlock');
  }

  Widget _buildPeopleTab(VaultController controller, List<VaultMedia> allItems) {
    final liveClusters = controller.localDbService.isOpen
        ? controller.localDbService.getAllFaceClusters()
        : controller.faceClusters;

    final unscannedCount = allItems.where((m) {
      final isImage = !_isVideoMedia(m);
      final hasCloud =
          m.chunkMessageIds.isNotEmpty || m.backupMessageIds.isNotEmpty;
      return isImage && hasCloud && !m.facesScanned;
    }).length;

    final scannedCount =
        allItems.where((m) => !_isVideoMedia(m) && m.facesScanned).length;

    final people = liveClusters.where((c) {
      if (_searchQuery.isEmpty) return true;
      return c.name.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    final shouldForceRescan = unscannedCount == 0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: GlassCard(
            width: double.infinity,
            borderRadius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(
                  Icons.face_retouching_natural_rounded,
                  color: Colors.cyanAccent,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.isScanningFaces
                            ? 'Scanning offline (${controller.faceScanDone}/${controller.faceScanTotal})...'
                            : '100% Offline Face Grouping',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        unscannedCount > 0
                            ? '$unscannedCount photo(s) ready to scan'
                            : '${liveClusters.length} people • $scannedCount scanned',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.isScanningFaces)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.cyanAccent,
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: () =>
                        _scanFacesOffline(forceRescan: shouldForceRescan),
                    icon: Icon(
                      shouldForceRescan
                          ? Icons.refresh_rounded
                          : Icons.document_scanner_outlined,
                      size: 16,
                      color: Colors.cyanAccent,
                    ),
                    label: Text(
                      shouldForceRescan ? 'Re-Scan' : 'Scan',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: people.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: GlassCard(
                      borderRadius: 24,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 28,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.people_outline_rounded,
                            size: 42,
                            color: Colors.cyanAccent,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            controller.lastFaceScanError != null
                                ? 'Scan error:\n${controller.lastFaceScanError}'
                                : scannedCount > 0
                                    ? '$scannedCount photo(s) scanned, no face groups yet.\nTap "Re-Scan" above to scan again.'
                                    : 'No people grouped yet.\nTap "Scan" above to group faces 100% offline on your phone.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: people.length,
                  itemBuilder: (context, index) {
                    final cluster = people[index];
                    return _PersonAvatarGridItem(
                      key: ValueKey(cluster.id),
                      cluster: cluster,
                      controller: controller,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                PersonDetailScreen(clusterId: cluster.id),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(vaultControllerProvider);
    final allItems = controller.localDbService.isOpen
        ? controller.localDbService.getAllMedia()
        : controller.mediaItems;

    final hasMissingPhotoThumbs = allItems.any((m) {
      if (_isVideoMedia(m)) return false;
      final hasCloud =
          m.chunkMessageIds.isNotEmpty || m.backupMessageIds.isNotEmpty;
      if (!hasCloud) return false;
      return m.localThumbPath == null ||
          m.localThumbPath!.isEmpty ||
          !File(m.localThumbPath!).existsSync();
    });

    final filtered = allItems.where((m) {
      if (_searchQuery.isNotEmpty &&
          !m.fileName.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      switch (_activeTab) {
        case _GalleryTab.all:
        case _GalleryTab.people:
          return true;
        case _GalleryTab.photos:
          return !_isVideoMedia(m);
        case _GalleryTab.videos:
          return _isVideoMedia(m);
        case _GalleryTab.favorites:
          return m.isFavorite;
      }
    }).toList();

    return GlowBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: _activeTab == _GalleryTab.people
                        ? 'Search people...'
                        : 'Search encrypted media...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                  onChanged: (val) =>
                      setState(() => _searchQuery = val.trim()),
                )
              : const Text(
                  'Pkrypt',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
          actions: [
            if (hasMissingPhotoThumbs && controller.isTelegramReady)
              IconButton(
                tooltip: 'Build Encrypted Previews',
                icon: controller.isBuildingThumbnails
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.amberAccent,
                        ),
                      )
                    : const Icon(
                        Icons.auto_awesome_rounded,
                        color: Colors.amberAccent,
                      ),
                onPressed: controller.isBuildingThumbnails
                    ? null
                    : _buildMissingPreviews,
              ),
            IconButton(
              tooltip: _isSearching ? 'Close Search' : 'Search',
              icon: Icon(_isSearching ? Icons.close : Icons.search_rounded),
              onPressed: () {
                setState(() {
                  _isSearching = !_isSearching;
                  if (!_isSearching) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _searchController.clear();
                    _searchQuery = '';
                  }
                });
              },
            ),
            IconButton(
              tooltip: 'Telegram Cloud',
              icon: Icon(
                controller.isTelegramReady
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: controller.isTelegramReady
                    ? Colors.cyanAccent
                    : Colors.orangeAccent,
              ),
              onPressed: () {
                if (controller.isDecoyMode) {
                  _showBanner('Cloud sync is offline. Local vault mode active.');
                  return;
                }
                Navigator.of(context).pushNamed('/telegram');
              },
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
            ),
            IconButton(
              tooltip: 'Lock Vault',
              icon: const Icon(Icons.lock_outline_rounded),
              onPressed: _lockNow,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_queueTotal > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                child: GlassCard(
                  width: double.infinity,
                  borderRadius: 16,
                  tintColor: const Color(0xFF06B6D4),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Streaming $_queueDone / $_queueTotal (${(controller.operationProgress * 100).toInt()}%) - ${_currentUploadingName ?? ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _queueTotal > 0
                            ? ((_queueDone + controller.operationProgress) /
                                    _queueTotal)
                                .clamp(0.0, 1.0)
                            : null,
                        color: Colors.cyanAccent,
                        backgroundColor: Colors.white12,
                      ),
                    ],
                  ),
                ),
              )
            else if (controller.isBusy)
              LinearProgressIndicator(
                value: controller.operationProgress > 0
                    ? controller.operationProgress
                    : null,
                color: Colors.cyanAccent,
                backgroundColor: Colors.white12,
              ),

            if (_statusBanner != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                child: GlassCard(
                  width: double.infinity,
                  borderRadius: 16,
                  tintColor:
                      _isBannerError ? Colors.redAccent : Colors.greenAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isBannerError
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline,
                        size: 18,
                        color: _isBannerError
                            ? Colors.redAccent
                            : Colors.greenAccent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _statusBanner!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _statusBanner = null),
                        child: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Horizontally Scrollable Liquid-Glass Filter Dock
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: GlassCard(
                width: double.infinity,
                borderRadius: 999,
                enableBlur: false,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _LiquidTab(
                          icon: Icons.grid_view_rounded,
                          label: 'All',
                          selected: _activeTab == _GalleryTab.all,
                          onTap: () =>
                              setState(() => _activeTab = _GalleryTab.all),
                        ),
                        const SizedBox(width: 6),
                        _LiquidTab(
                          icon: Icons.photo_outlined,
                          label: 'Photos',
                          selected: _activeTab == _GalleryTab.photos,
                          onTap: () =>
                              setState(() => _activeTab = _GalleryTab.photos),
                        ),
                        const SizedBox(width: 6),
                        _LiquidTab(
                          icon: Icons.videocam_outlined,
                          label: 'Videos',
                          selected: _activeTab == _GalleryTab.videos,
                          onTap: () =>
                              setState(() => _activeTab = _GalleryTab.videos),
                        ),
                        const SizedBox(width: 6),
                        _LiquidTab(
                          icon: Icons.people_outline_rounded,
                          label: 'People',
                          selected: _activeTab == _GalleryTab.people,
                          onTap: () =>
                              setState(() => _activeTab = _GalleryTab.people),
                        ),
                        const SizedBox(width: 6),
                        _LiquidTab(
                          icon: Icons.favorite_border_rounded,
                          label: 'Favs',
                          selected: _activeTab == _GalleryTab.favorites,
                          onTap: () => setState(
                            () => _activeTab = _GalleryTab.favorites,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ),

            // Main Content Area (People Grid OR Encrypted Media Grid)
            Expanded(
              child: _activeTab == _GalleryTab.people
                  ? _buildPeopleTab(controller, allItems)
                  : filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: FloatingWidget(
                              amplitude: 5,
                              durationMs: 3200,
                              child: GlassCard(
                                borderRadius: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 28,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _activeTab == _GalleryTab.videos
                                          ? Icons.videocam_off_outlined
                                          : Icons.lock_outline_rounded,
                                      size: 40,
                                      color: Colors.cyanAccent,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _searchQuery.isNotEmpty
                                          ? 'No media found for "$_searchQuery".'
                                          : 'No encrypted media here yet.\nTap the floating + button to upload photos or videos.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color:
                                            Colors.white.withValues(alpha: 0.72),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        )
                      : GridView.builder(
                          physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final media = filtered[index];
                            return _MediaGlassCard(
                              key: ValueKey(media.id),
                              media: media,
                              controller: controller,
                              isVideo: _isVideoMedia(media),
                              onFavorite: () =>
                                  controller.toggleFavorite(media),
                              onTap: () {
                                Navigator.of(context).pushNamed(
                                  '/viewer',
                                  arguments: {
                                    'items': filtered,
                                    'initialIndex': index,
                                  },
                                );
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButton: SafeArea(
          top: false,
          left: false,
          child: Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: GlassIconButton(
              icon: Icons.add_rounded,
              onTap: (controller.isBusy || _queueTotal > 0)
                  ? null
                  : _openUploadPickerSheet,
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonAvatarGridItem extends StatefulWidget {
  final FaceCluster cluster;
  final VaultController controller;
  final VoidCallback onTap;

  const _PersonAvatarGridItem({
    super.key,
    required this.cluster,
    required this.controller,
    required this.onTap,
  });

  @override
  State<_PersonAvatarGridItem> createState() => _PersonAvatarGridItemState();
}

class _PersonAvatarGridItemState extends State<_PersonAvatarGridItem> {
  Uint8List? _avatarBytes;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  @override
  void didUpdateWidget(covariant _PersonAvatarGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cluster.id != widget.cluster.id ||
        oldWidget.cluster.avatarPath != widget.cluster.avatarPath) {
      _loadAvatar();
    }
  }

  void _loadAvatar() {
    final cached = widget.controller.getCachedFaceAvatar(widget.cluster.id);
    if (cached != null) {
      _avatarBytes = cached;
      return;
    }
    widget.controller.loadFaceAvatar(widget.cluster).then((bytes) {
      if (mounted && bytes != null) {
        setState(() => _avatarBytes = bytes);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaCount =
        widget.controller.getMediaForPerson(widget.cluster.id).length;
    return PersonTile(
      name: widget.cluster.name,
      avatarBytes: _avatarBytes ??
          widget.controller.getCachedFaceAvatar(widget.cluster.id),
      mediaCount: mediaCount,
      onTap: widget.onTap,
    );
  }
}

class _LiquidTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LiquidTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected
              ? Colors.cyanAccent.withValues(alpha: 0.24)
              : Colors.transparent,
          border: selected
              ? Border.all(
                  color: Colors.cyanAccent.withValues(alpha: 0.65),
                  width: 1,
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.cyanAccent : Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaGlassCard extends StatefulWidget {
  final VaultMedia media;
  final VaultController controller;
  final bool isVideo;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  const _MediaGlassCard({
    super.key,
    required this.media,
    required this.controller,
    required this.isVideo,
    required this.onTap,
    required this.onFavorite,
  });

  @override
  State<_MediaGlassCard> createState() => _MediaGlassCardState();
}

class _MediaGlassCardState extends State<_MediaGlassCard> {
  Uint8List? _thumbBytes;
  bool _loadingThumb = false;

  @override
  void initState() {
    super.initState();
    _initThumb();
  }

  @override
  void didUpdateWidget(covariant _MediaGlassCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != widget.media.id ||
        oldWidget.media.localThumbPath != widget.media.localThumbPath) {
      _initThumb();
    }
  }

  void _initThumb() {
    final cached = widget.controller.getCachedThumbnail(widget.media.id);
    if (cached != null) {
      _thumbBytes = cached;
      return;
    }

    if (_loadingThumb) return;
    _loadingThumb = true;
    widget.controller.loadEncryptedThumbnail(widget.media).then((bytes) {
      _loadingThumb = false;
      if (!mounted) return;
      if (bytes != null) {
        setState(() => _thumbBytes = bytes);
      }
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final hasCloudIds = media.chunkMessageIds.isNotEmpty ||
        media.backupMessageIds.isNotEmpty ||
        (media.localEncryptedPath != null &&
            media.localEncryptedPath!.isNotEmpty);
    final thumb = _thumbBytes ?? widget.controller.getCachedThumbnail(media.id);

    if (thumb != null && thumb.isNotEmpty) {
      return RepaintBoundary(
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    thumb,
                    fit: BoxFit.cover,
                    cacheWidth: 360,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                  ),
                  if (widget.isVideo)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.55),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.45),
                            width: 1,
                          ),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(7, 16, 7, 6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.72),
                          ],
                        ),
                      ),
                      child: Text(
                        widget.isVideo
                            ? 'VIDEO \u2022 ${_formatSize(media.sizeBytes)}'
                            : _formatSize(media.sizeBytes),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      onTap: widget.onFavorite,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.42),
                        ),
                        child: Icon(
                          media.isFavorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 15,
                          color: media.isFavorite
                              ? Colors.pinkAccent
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: GlassCard(
        borderRadius: 18,
        padding: const EdgeInsets.all(8),
        enableBlur: false,
        tintColor: !hasCloudIds
            ? Colors.redAccent
            : (widget.isVideo ? const Color(0xFF7C3AED) : null),
        onTap: widget.onTap,
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    !hasCloudIds
                        ? Icons.cloud_off_rounded
                        : (widget.isVideo
                            ? Icons.play_circle_outline_rounded
                            : Icons.enhanced_encryption_outlined),
                    color: !hasCloudIds
                        ? Colors.redAccent
                        : (widget.isVideo
                            ? Colors.purpleAccent
                            : Colors.cyanAccent),
                    size: 30,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    media.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    !hasCloudIds
                        ? 'Failed'
                        : '${widget.isVideo ? "VIDEO" : "PHOTO"} • ${_formatSize(media.sizeBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: !hasCloudIds
                          ? Colors.redAccent
                          : Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                onTap: widget.onFavorite,
                child: Icon(
                  media.isFavorite ? Icons.favorite : Icons.favorite_border,
                  size: 18,
                  color: media.isFavorite ? Colors.pinkAccent : Colors.white54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}