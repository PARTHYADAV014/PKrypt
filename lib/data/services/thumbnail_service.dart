import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../models/vault_media.dart';
import 'crypto_service.dart';

/// Top-level isolate function: resizes image to max 320px & fixes EXIF rotation.
Uint8List? _encodeThumbnailIsolate(Uint8List sourceBytes) {
  try {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) return null;

    final oriented = img.bakeOrientation(decoded);
    final img.Image resized;
    if (oriented.width >= oriented.height && oriented.width > 320) {
      resized = img.copyResize(oriented, width: 320);
    } else if (oriented.height > oriented.width && oriented.height > 320) {
      resized = img.copyResize(oriented, height: 320);
    } else {
      resized = oriented;
    }

    return img.encodeJpg(resized, quality: 75);
  } catch (_) {
    return null;
  }
}

class ThumbnailService {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.vaultgallery/sync_service');
  static const int defaultMaxRamBytes = 24 * 1024 * 1024; // ~1,500 thumbnails
  static const int _maxSourceBytesForThumb = 40 * 1024 * 1024; // 40 MB image guard

  final CryptoService _crypto;
  final int maxRamBytes;

  final LinkedHashMap<String, Uint8List> _ramCache =
      LinkedHashMap<String, Uint8List>();
  int _currentRamBytes = 0;

  ThumbnailService({
    required CryptoService cryptoService,
    this.maxRamBytes = defaultMaxRamBytes,
  }) : _crypto = cryptoService;

  static bool _isVideoMimeOrPath(String mimeType, String filePath) {
    final m = mimeType.toLowerCase();
    if (m.startsWith('video/')) return true;
    final p = filePath.toLowerCase();
    return p.endsWith('.mp4') ||
        p.endsWith('.mov') ||
        p.endsWith('.mkv') ||
        p.endsWith('.webm') ||
        p.endsWith('.3gp') ||
        p.endsWith('.m4v') ||
        p.endsWith('.avi');
  }

  Uint8List? getCachedThumb(String mediaId) {
    final existing = _ramCache.remove(mediaId);
    if (existing != null) {
      _ramCache[mediaId] = existing;
    }
    return existing;
  }

  Future<Directory> _resolveThumbDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docsDir.path}${Platform.pathSeparator}vault_thumbs',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _thumbFileFor(String mediaId, {String? customPath}) async {
    if (customPath != null && customPath.isNotEmpty) {
      return File(customPath);
    }
    final dir = await _resolveThumbDir();
    return File('${dir.path}${Platform.pathSeparator}$mediaId.vthumb');
  }

  /// Creates an AES-256-GCM encrypted thumbnail from plaintext image bytes.
  Future<String?> generateAndSaveFromBytes({
    required String mediaId,
    required Uint8List plainImageBytes,
  }) async {
    if (!_crypto.isUnlocked || plainImageBytes.isEmpty) return null;
    if (plainImageBytes.length > _maxSourceBytesForThumb) return null;

    final thumbJpg = await compute(_encodeThumbnailIsolate, plainImageBytes);
    if (thumbJpg == null || thumbJpg.isEmpty) return null;

    final encryptedThumb = await _crypto.encrypt(thumbJpg);
    final file = await _thumbFileFor(mediaId);
    await file.writeAsBytes(encryptedThumb, flush: true);

    _putInRamCache(mediaId, thumbJpg);
    return file.path;
  }

  /// Extracts a video frame natively on Android and saves it as an encrypted `.vthumb`.
  Future<String?> generateAndSaveFromVideoFile({
    required String mediaId,
    required String filePath,
  }) async {
    if (!_crypto.isUnlocked || filePath.isEmpty) return null;
    if (!Platform.isAndroid) return null;

    final file = File(filePath);
    if (!await file.exists()) return null;

    try {
      final thumbJpg = await _nativeChannel.invokeMethod<Uint8List>(
        'extractVideoThumbnail',
        {
          'path': filePath,
          'maxWidth': 360,
        },
      );
      if (thumbJpg == null || thumbJpg.isEmpty) return null;

      final encryptedThumb = await _crypto.encrypt(thumbJpg);
      final outFile = await _thumbFileFor(mediaId);
      await outFile.writeAsBytes(encryptedThumb, flush: true);

      _putInRamCache(mediaId, thumbJpg);
      return outFile.path;
    } catch (_) {
      return null;
    }
  }

  /// Creates an encrypted thumbnail directly from a local image OR video file path.
  Future<String?> generateAndSaveFromFile({
    required String mediaId,
    required String filePath,
    required String mimeType,
  }) async {
    if (!_crypto.isUnlocked) return null;

    if (_isVideoMimeOrPath(mimeType, filePath)) {
      return generateAndSaveFromVideoFile(
        mediaId: mediaId,
        filePath: filePath,
      );
    }

    if (!mimeType.toLowerCase().startsWith('image/')) return null;

    final file = File(filePath);
    if (!await file.exists()) return null;
    final len = await file.length();
    if (len <= 0 || len > _maxSourceBytesForThumb) return null;

    final bytes = await file.readAsBytes();
    return generateAndSaveFromBytes(
      mediaId: mediaId,
      plainImageBytes: bytes,
    );
  }

  /// Loads and decrypts an existing `.vthumb` file strictly into RAM.
  Future<Uint8List?> loadDecryptedThumb(VaultMedia media) async {
    if (!_crypto.isUnlocked) return null;

    final cached = getCachedThumb(media.id);
    if (cached != null) return cached;

    try {
      File file = await _thumbFileFor(
        media.id,
        customPath: media.localThumbPath,
      );
      if (!await file.exists() && media.localThumbPath != null) {
        file = await _thumbFileFor(media.id);
      }
      if (!await file.exists()) return null;

      final encryptedBytes = await file.readAsBytes();
      if (encryptedBytes.isEmpty) return null;

      final plainThumb = await _crypto.decrypt(encryptedBytes);
      _putInRamCache(media.id, plainThumb);
      return plainThumb;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteThumb(String mediaId, {String? customPath}) async {
    final removed = _ramCache.remove(mediaId);
    if (removed != null) {
      _currentRamBytes -= removed.length;
      removed.fillRange(0, removed.length, 0);
    }

    try {
      final file = await _thumbFileFor(mediaId, customPath: customPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> wipeAllThumbs() async {
    clearRamCache();
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_thumbs',
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  void _putInRamCache(String mediaId, Uint8List bytes) {
    if (bytes.length > maxRamBytes) return;

    final previous = _ramCache.remove(mediaId);
    if (previous != null) {
      _currentRamBytes -= previous.length;
    }

    while (_currentRamBytes + bytes.length > maxRamBytes &&
        _ramCache.isNotEmpty) {
      final oldestKey = _ramCache.keys.first;
      final evicted = _ramCache.remove(oldestKey)!;
      _currentRamBytes -= evicted.length;
      evicted.fillRange(0, evicted.length, 0);
    }

    _ramCache[mediaId] = bytes;
    _currentRamBytes += bytes.length;
  }

  void clearRamCache() {
    for (final bytes in _ramCache.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _ramCache.clear();
    _currentRamBytes = 0;
  }
}