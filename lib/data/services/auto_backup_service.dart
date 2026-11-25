import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vault_media.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'local_db_service.dart';
import 'telegram_service.dart';
import 'upload_service.dart';

class DeviceAlbumInfo {
  final String id;
  final String name;
  final int assetCount;

  const DeviceAlbumInfo({
    required this.id,
    required this.name,
    required this.assetCount,
  });
}

class AutoBackupService {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.vaultgallery/sync_service');

  static const String _prefEnabled = 'vg_auto_backup_enabled_v1';
  static const String _prefWifiOnly = 'vg_auto_backup_wifi_only_v1';
  static const String _prefAlbumIds = 'vg_auto_backup_album_ids_v1';
  static const String _prefPrimaryChatId = 'vg_auto_backup_primary_chat_v1';
  static const String _prefBackupChatId = 'vg_auto_backup_backup_chat_v1';
  static const String _prefUploadedHashes = 'vg_auto_backup_hashes_v1';
  static const String _prefSealedQueue = 'vg_auto_backup_sealed_queue_v1';
  static const String _prefLastSyncMs = 'vg_auto_backup_last_sync_v1';

  final CryptoService _crypto;
  final AuthService _auth;
  final LocalDbService _db;
  final TelegramService _telegram;
  final UploadService _uploader;

  VoidCallback? onStateChanged;
  VoidCallback? onUnlockedMediaAdded;

  SharedPreferences? _prefs;
  bool _enabled = false;
  bool _wifiOnly = true;
  List<String> _selectedAlbumIds = const [];
  int? _cachedPrimaryChatId;
  int? _cachedBackupChatId;
  Set<String> _knownHashes = <String>{};
  List<String> _sealedQueue = <String>[];
  DateTime? _lastSyncAt;

  bool _isSyncing = false;
  String _statusMessage = 'Off';
  int _sessionUploadedCount = 0;

  Timer? _periodicTimer;
  Timer? _debounceTimer;
  bool _watchingGallery = false;

  AutoBackupService({
    required CryptoService cryptoService,
    required AuthService authService,
    required LocalDbService localDbService,
    required TelegramService telegramService,
    required UploadService uploadService,
  })  : _crypto = cryptoService,
        _auth = authService,
        _db = localDbService,
        _telegram = telegramService,
        _uploader = uploadService;

  bool get isEnabled => _enabled;
  bool get wifiOnly => _wifiOnly;
  List<String> get selectedAlbumIds => List.unmodifiable(_selectedAlbumIds);
  bool get isSyncing => _isSyncing;
  String get statusMessage => _statusMessage;
  int get sessionUploadedCount => _sessionUploadedCount;
  int get pendingSealedCount => _sealedQueue.length;
  DateTime? get lastSyncAt => _lastSyncAt;

  void _notify() => onStateChanged?.call();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _enabled = _prefs!.getBool(_prefEnabled) ?? false;
    _wifiOnly = _prefs!.getBool(_prefWifiOnly) ?? true;
    _selectedAlbumIds = _prefs!.getStringList(_prefAlbumIds) ?? const [];
    _cachedPrimaryChatId = _prefs!.getInt(_prefPrimaryChatId);
    _cachedBackupChatId = _prefs!.getInt(_prefBackupChatId);
    _knownHashes = (_prefs!.getStringList(_prefUploadedHashes) ?? const []).toSet();
    _sealedQueue =
        List<String>.from(_prefs!.getStringList(_prefSealedQueue) ?? const []);
    final lastMs = _prefs!.getInt(_prefLastSyncMs);
    if (lastMs != null) {
      _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }

    _statusMessage = _enabled ? 'Active (Zero-Knowledge Ready)' : 'Off';
    if (_enabled) {
      await _startBackgroundEngine();
    }
    _notify();
  }

  /// Syncs channel IDs and SHA-256 hashes from Hive so locked-mode backup
  /// knows where to upload and skips already-uploaded items.
  Future<void> syncVaultContext({
    required int? primaryChatId,
    required int? backupChatId,
    required Set<String> dbHashes,
  }) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    if (primaryChatId != null) {
      _cachedPrimaryChatId = primaryChatId;
      await prefs.setInt(_prefPrimaryChatId, primaryChatId);
    }

    _cachedBackupChatId = backupChatId;
    if (backupChatId != null) {
      await prefs.setInt(_prefBackupChatId, backupChatId);
    } else {
      await prefs.remove(_prefBackupChatId);
    }

    if (dbHashes.isNotEmpty) {
      _knownHashes.addAll(dbHashes);
      await prefs.setStringList(_prefUploadedHashes, _knownHashes.toList());
    }
  }

  Future<bool> requestPermissions() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth && !perm.hasAccess) {
      return false;
    }
    await _invokeNative('requestNotificationPermission');
    return true;
  }

  Future<void> openAppPermissionSettings() async {
    await PhotoManager.openSetting();
  }

  Future<bool> openBatteryOptimizationSettings() async {
    final res = await _invokeNative('openBatteryOptimizationSettings');
    return res == true;
  }

  Future<List<DeviceAlbumInfo>> getAvailableDeviceAlbums() async {
    final granted = await requestPermissions();
    if (!granted) return const [];

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
    );

    final result = <DeviceAlbumInfo>[];
    for (final p in paths) {
      if (p.isAll) continue;
      final count = await p.assetCountAsync;
      if (count > 0) {
        result.add(
          DeviceAlbumInfo(id: p.id, name: p.name, assetCount: count),
        );
      }
    }
    result.sort((a, b) => b.assetCount.compareTo(a.assetCount));
    return result;
  }

  Future<bool> setEnabled(bool enable) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    if (enable) {
      final granted = await requestPermissions();
      if (!granted) {
        _statusMessage = 'Gallery permission denied';
        _notify();
        return false;
      }

      if (_cachedPrimaryChatId == null && _db.isOpen) {
        _cachedPrimaryChatId = _db.getPrimaryChannel()?.chatId;
        if (_cachedPrimaryChatId != null) {
          await prefs.setInt(_prefPrimaryChatId, _cachedPrimaryChatId!);
        }
      }

      if (_cachedPrimaryChatId == null) {
        _statusMessage = 'Select a Primary Vault Channel first';
        _notify();
        return false;
      }

      _enabled = true;
      await prefs.setBool(_prefEnabled, true);
      _statusMessage = 'Active (Zero-Knowledge Ready)';
      await _startBackgroundEngine();
      _notify();
      unawaited(triggerSyncNow());
      return true;
    } else {
      _enabled = false;
      await prefs.setBool(_prefEnabled, false);
      await _stopBackgroundEngine();
      _statusMessage = 'Off';
      _notify();
      return true;
    }
  }

  Future<void> setWifiOnly(bool value) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    _wifiOnly = value;
    await prefs.setBool(_prefWifiOnly, value);
    _notify();
  }

  Future<void> setSelectedAlbumIds(List<String> albumIds) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    _selectedAlbumIds = List<String>.from(albumIds);
    await prefs.setStringList(_prefAlbumIds, _selectedAlbumIds);
    _notify();
    if (_enabled) {
      unawaited(triggerSyncNow());
    }
  }

  /// Decrypts sealed X25519 metadata uploaded while vault was locked and saves to Hive.
  Future<int> absorbSealedQueueIfUnlocked() async {
    if (!_crypto.isUnlocked || !_db.isOpen || _sealedQueue.isEmpty) {
      return 0;
    }

    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;

    final remaining = <String>[];
    int absorbed = 0;

    for (final sealedB64 in _sealedQueue) {
      try {
        final sealedBytes = base64Decode(sealedB64);
        final plainBytes = await _crypto.decrypt(sealedBytes);
        final decoded = jsonDecode(utf8.decode(plainBytes));
        if (decoded is Map) {
          final media = VaultMedia.fromMap(decoded);
          await _db.saveMedia(media);
          absorbed++;
        }
      } catch (_) {
        remaining.add(sealedB64);
      }
    }

    _sealedQueue = remaining;
    await prefs.setStringList(_prefSealedQueue, _sealedQueue);
    if (absorbed > 0) {
      _notify();
    }
    return absorbed;
  }

  /// Scans selected folders (defaults to Camera if none chosen) and uploads new files.
  /// Works both UNLOCKED (AES-GCM direct to Hive) and LOCKED (X25519 VGZ1 + sealed queue).
  Future<int> triggerSyncNow({int maxAssetsPerFolder = 30}) async {
    if (_isSyncing) return 0;

    final primaryChatId = _db.isOpen
        ? (_db.getPrimaryChannel()?.chatId ?? _cachedPrimaryChatId)
        : _cachedPrimaryChatId;
    final backupChatId = _db.isOpen
        ? (_db.getBackupChannel()?.chatId ?? _cachedBackupChatId)
        : _cachedBackupChatId;

    if (primaryChatId == null) {
      _statusMessage = 'Primary Vault Channel not set';
      _notify();
      return 0;
    }

    if (!_telegram.isReady) {
      _statusMessage = 'Waiting for Telegram connection...';
      _notify();
      return 0;
    }

    if (_wifiOnly) {
      final onWifi = await _isWifiConnected();
      if (!onWifi) {
        _statusMessage = 'Paused (Waiting for Wi-Fi)';
        _notify();
        return 0;
      }
    }

    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth && !perm.hasAccess) {
      _statusMessage = 'Gallery permission required';
      _notify();
      return 0;
    }

    _isSyncing = true;
    _statusMessage = 'Scanning gallery for new media...';
    _notify();

    int uploadedThisRun = 0;

    try {
      await _updateNotification(
        'Pkrypt Auto-Backup',
        'Scanning for new photos & videos...',
      );

      final targetPaths = await _resolveTargetAlbumPaths();
      final assetsToCheck = <MapEntry<String, AssetEntity>>[];

      for (final albumPath in targetPaths) {
        final assets = await albumPath.getAssetListPaged(
          page: 0,
          size: maxAssetsPerFolder,
        );
        for (final asset in assets) {
          assetsToCheck.add(MapEntry(albumPath.name, asset));
        }
      }

      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;

      int processed = 0;
      for (final entry in assetsToCheck) {
        if (!_enabled && !(_crypto.isUnlocked && _db.isOpen)) break;

        if (_wifiOnly && !await _isWifiConnected()) {
          _statusMessage = 'Paused (Wi-Fi disconnected)';
          break;
        }

        processed++;
        final albumName = entry.key;
        final asset = entry.value;

        File? file;
        try {
          file = await asset.originFile ?? await asset.file;
        } catch (_) {
          file = null;
        }
        if (file == null || !await file.exists()) continue;

        final fileLen = await file.length();
        if (fileLen <= 0) continue;

        final sha256 = await _uploader.computeFileSha256(file.path);
        if (_knownHashes.contains(sha256)) continue;

        if (_db.isOpen && _db.findMediaByHash(sha256) != null) {
          _knownHashes.add(sha256);
          await prefs.setStringList(_prefUploadedHashes, _knownHashes.toList());
          continue;
        }

        final fileName = _resolveFileName(asset, file.path);
        final mimeType = _resolveMimeType(asset, fileName);

        _statusMessage = 'Encrypting $fileName ($processed/${assetsToCheck.length})';
        _notify();
        await _updateNotification(
          'Pkrypt Auto-Backup',
          'Encrypting & uploading $fileName...',
        );

        try {
          if (_crypto.isUnlocked && _db.isOpen) {
            await _uploader.uploadFileStream(
              filePath: file.path,
              fileName: fileName,
              mimeType: mimeType,
              album: albumName,
              skipIfDuplicate: true,
            );
            _knownHashes.add(sha256);
            await prefs.setStringList(
              _prefUploadedHashes,
              _knownHashes.toList(),
            );
            uploadedThisRun++;
            _sessionUploadedCount++;
            onUnlockedMediaAdded?.call();
          } else {
            // LOCKED-STATE ZERO-KNOWLEDGE MODE (X25519 Public Key Only)
            final pubKey = await _auth.getX25519PublicKeyBytes();
            if (pubKey == null) {
              _statusMessage = 'Unlock once to initialize X25519 key';
              break;
            }

            final res = await _uploader.uploadFileLockedWithPublicKey(
              filePath: file.path,
              primaryChatId: primaryChatId,
              backupChatId: backupChatId,
              x25519PublicKeyBytes: pubKey,
            );

            final pendingMedia = VaultMedia(
              id: res.mediaId,
              fileName: fileName,
              mimeType: mimeType,
              sizeBytes: res.sizeBytes,
              createdAt: asset.createDateTime,
              album: albumName,
              uploadStatus: 'uploaded',
              primaryChatId: primaryChatId,
              chunkMessageIds: res.chunkMessageIds,
              backupChatId: res.backupChatId,
              backupMessageIds: res.backupMessageIds,
              contentHash: res.contentHash,
              isPerChunkEncrypted: res.isPerChunkEncrypted,
            );

            final metaPlain =
                Uint8List.fromList(utf8.encode(jsonEncode(pendingMedia.toMap())));
            final sealedMeta = await _crypto.encryptForPublicKey(
              plaintext: metaPlain,
              recipientPublicKeyBytes: pubKey,
            );

            _sealedQueue.add(base64Encode(sealedMeta));
            await prefs.setStringList(_prefSealedQueue, _sealedQueue);

            _knownHashes.add(res.contentHash);
            await prefs.setStringList(
              _prefUploadedHashes,
              _knownHashes.toList(),
            );
            uploadedThisRun++;
            _sessionUploadedCount++;
          }
        } on DuplicateMediaException {
          _knownHashes.add(sha256);
          await prefs.setStringList(_prefUploadedHashes, _knownHashes.toList());
        } catch (_) {
          // Skip transient single-file failure and keep queue moving
        }
      }

      _lastSyncAt = DateTime.now();
      await prefs.setInt(_prefLastSyncMs, _lastSyncAt!.millisecondsSinceEpoch);

      if (!_statusMessage.startsWith('Paused') &&
          !_statusMessage.startsWith('Unlock')) {
        _statusMessage = uploadedThisRun > 0
            ? 'Synced $uploadedThisRun new item(s)'
            : 'Up to date (Zero-Knowledge Active)';
      }

      if (_enabled) {
        await _updateNotification(
          'Pkrypt Auto-Backup',
          _statusMessage,
        );
      }
      return uploadedThisRun;
    } finally {
      _isSyncing = false;
      _notify();
    }
  }

  Future<List<AssetPathEntity>> _resolveTargetAlbumPaths() async {
    final allPaths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
    );

    if (_selectedAlbumIds.isNotEmpty) {
      final selectedSet = _selectedAlbumIds.toSet();
      final matched = allPaths.where((p) => selectedSet.contains(p.id)).toList();
      if (matched.isNotEmpty) return matched;
    }

    // Default to Camera folder when user hasn't picked specific folders yet
    final cameraFolders = allPaths
        .where(
          (p) =>
              !p.isAll &&
              (p.name.toLowerCase() == 'camera' ||
                  p.name.toLowerCase().contains('dcim')),
        )
        .toList();
    if (cameraFolders.isNotEmpty) return cameraFolders;

    final recent = allPaths.where((p) => p.isAll).toList();
    if (recent.isNotEmpty) return recent;
    return allPaths.take(1).toList();
  }

  String _resolveFileName(AssetEntity asset, String path) {
    final title = asset.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final sep = Platform.pathSeparator;
    final idx = path.lastIndexOf(sep);
    return idx >= 0 ? path.substring(idx + 1) : 'vault_${asset.id}';
  }

  String _resolveMimeType(AssetEntity asset, String fileName) {
    final m = asset.mimeType;
    if (m != null && m.isNotEmpty) return m;
    if (asset.type == AssetType.video) return 'video/mp4';
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  void _onGalleryChanged(MethodCall call) {
    if (!_enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 4), () {
      unawaited(triggerSyncNow());
    });
  }

  Future<void> _startBackgroundEngine() async {
    await _invokeNative('startForegroundSync', {
      'title': 'Pkrypt Auto-Backup',
      'text': 'Zero-knowledge background sync active',
    });

    if (!_watchingGallery) {
      try {
        PhotoManager.addChangeCallback(_onGalleryChanged);
        await PhotoManager.startChangeNotify();
        _watchingGallery = true;
      } catch (_) {}
    }

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_enabled) {
        unawaited(triggerSyncNow());
      }
    });
  }

  Future<void> _stopBackgroundEngine() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;

    if (_watchingGallery) {
      try {
        PhotoManager.removeChangeCallback(_onGalleryChanged);
        await PhotoManager.stopChangeNotify();
      } catch (_) {}
      _watchingGallery = false;
    }

    await _invokeNative('stopForegroundSync');
  }

  Future<bool> _isWifiConnected() async {
    final res = await _invokeNative('isWifiConnected');
    if (res is bool) return res;
    return true;
  }

  Future<void> _updateNotification(String title, String text) async {
    if (!_enabled) return;
    await _invokeNative('updateForegroundSync', {
      'title': title,
      'text': text,
    });
  }

  Future<dynamic> _invokeNative(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _nativeChannel.invokeMethod(method, args);
    } catch (_) {
      return null;
    }
  }

  Future<void> wipeAllData() async {
    await _stopBackgroundEngine();
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_prefEnabled);
    await prefs.remove(_prefWifiOnly);
    await prefs.remove(_prefAlbumIds);
    await prefs.remove(_prefPrimaryChatId);
    await prefs.remove(_prefBackupChatId);
    await prefs.remove(_prefUploadedHashes);
    await prefs.remove(_prefSealedQueue);
    await prefs.remove(_prefLastSyncMs);
    _enabled = false;
    _selectedAlbumIds = const [];
    _cachedPrimaryChatId = null;
    _cachedBackupChatId = null;
    _knownHashes.clear();
    _sealedQueue.clear();
    _lastSyncAt = null;
    _statusMessage = 'Off';
    _notify();
  }

  void dispose() {
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    if (_watchingGallery) {
      try {
        PhotoManager.removeChangeCallback(_onGalleryChanged);
      } catch (_) {}
      _watchingGallery = false;
    }
  }
}