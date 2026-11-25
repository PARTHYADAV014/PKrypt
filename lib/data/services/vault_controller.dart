import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/face_cluster.dart';
import '../models/vault_channel.dart';
import '../models/vault_media.dart';
import 'auth_service.dart';
import 'auto_backup_service.dart';
import 'channel_service.dart';
import 'crypto_service.dart';
import 'download_service.dart';
import 'face_grouping_service.dart';
import 'index_backup_service.dart';
import 'local_db_service.dart';
import 'telegram_service.dart';
import 'thumbnail_service.dart';
import 'upload_service.dart';

class VaultController extends ChangeNotifier {
  final CryptoService cryptoService;
  final AuthService authService;
  final LocalDbService localDbService;
  final TelegramService telegramService;
  final ChannelService channelService;
  final UploadService uploadService;
  final DownloadService downloadService;
  final IndexBackupService? indexBackupService;
  final AutoBackupService? autoBackupService;
  final ThumbnailService? thumbnailService;
  final FaceGroupingService? faceGroupingService;

  bool isInitialized = false;
  bool isDecoyMode = false;
  bool isBusy = false;
  bool isSyncingIndex = false;
  bool isSyncingKeyBundle = false;
  bool isBuildingThumbnails = false;
  bool isScanningFaces = false;
  int faceScanDone = 0;
  int faceScanTotal = 0;
  String? lastFaceScanError;
  DateTime? lastIndexBackupAt;
  DateTime? lastKeyBundleSyncAt;
  double operationProgress = 0.0;
  String? lastError;
  String? pendingRecoveryKey;
  String? pendingWipeCode;
  String selectedAlbum = 'All';
  bool onlyFavorites = false;
  List<VaultMedia> mediaItems = const [];
  List<VaultChannel> channels = const [];
  List<FaceCluster> faceClusters = const [];

  Timer? _autoBackupTimer;
  StreamSubscription<TelegramAuthStatus>? _telegramAuthSub;

  VaultController({
    required this.cryptoService,
    required this.authService,
    required this.localDbService,
    required this.telegramService,
    required this.channelService,
    required this.uploadService,
    required this.downloadService,
    this.indexBackupService,
    this.autoBackupService,
    this.thumbnailService,
    this.faceGroupingService,
  }) {
    _telegramAuthSub = telegramService.authStatusStream.listen((status) {
      notifyListeners();
      if (status == TelegramAuthStatus.ready &&
          (autoBackupService?.isEnabled ?? false)) {
        unawaited(autoBackupService!.triggerSyncNow());
      }
    });

    if (autoBackupService != null) {
      autoBackupService!.onStateChanged = notifyListeners;
      autoBackupService!.onUnlockedMediaAdded = () {
        if (isDecoyMode) return;
        refreshVaultData();
        _scheduleAutoIndexBackup();
      };
    }
  }

  static bool isVideoFile(VaultMedia media) {
    if (media.mimeType.toLowerCase().startsWith('video/')) return true;
    final lower = media.fileName.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.3gp') ||
        lower.endsWith('.avi');
  }

  bool get isUnlocked => cryptoService.isUnlocked && localDbService.isOpen;
  bool get isTelegramReady => !isDecoyMode && telegramService.isReady;
  VaultChannel? get primaryChannel =>
      localDbService.isOpen ? channelService.getPrimaryChannel() : null;
  VaultChannel? get backupChannel =>
      localDbService.isOpen ? channelService.getBackupChannel() : null;

  Uint8List? getCachedThumbnail(String mediaId) =>
      thumbnailService?.getCachedThumb(mediaId);

  Future<Uint8List?> loadEncryptedThumbnail(VaultMedia media) async {
    final svc = thumbnailService;
    if (svc == null || !isUnlocked) return null;
    return svc.loadDecryptedThumb(media);
  }

  Uint8List? getCachedFaceAvatar(String clusterId) =>
      faceGroupingService?.getCachedAvatar(clusterId);

  Future<Uint8List?> loadFaceAvatar(FaceCluster cluster) async {
    final svc = faceGroupingService;
    if (svc == null || !isUnlocked) return null;
    return svc.loadDecryptedAvatar(cluster);
  }

  List<VaultMedia> getMediaForPerson(String clusterId) {
    if (!localDbService.isOpen) return const [];
    return localDbService.getMediaForFaceCluster(clusterId);
  }

  /// Offline batch face scan. Set [forceRescan] to re-evaluate already-scanned photos.
  Future<int> scanFacesForUnscannedMedia({
    int maxCount = 50,
    bool forceRescan = false,
  }) async {
    final svc = faceGroupingService;
    if (svc == null || !isUnlocked || isScanningFaces) return 0;

    final existingClusters = localDbService.getAllFaceClusters();
    final hasLegacyHogClusters =
        existingClusters.any((c) => c.embedding.length == 140);
    final shouldReset = forceRescan || hasLegacyHogClusters;

    if (shouldReset) {
      await svc.wipeAllAvatars();
      await localDbService.clearAllFaceClusters();
      for (final m in localDbService.getAllMedia()) {
        if (m.facesScanned || m.faceClusterIds.isNotEmpty) {
          await localDbService.saveMedia(
            m.copyWith(faceClusterIds: const [], facesScanned: false),
          );
        }
      }
      refreshVaultData();
    }

    final candidates = localDbService
        .getAllMedia()
        .where((m) {
          final isImage = !isVideoFile(m);
          final hasCloud =
              m.chunkMessageIds.isNotEmpty || m.backupMessageIds.isNotEmpty;
          return isImage && hasCloud && (shouldReset || !m.facesScanned);
        })
        .take(shouldReset ? 200 : maxCount)
        .toList();

    if (candidates.isEmpty) return 0;

    isScanningFaces = true;
    faceScanDone = 0;
    faceScanTotal = candidates.length;
    lastFaceScanError = null;
    notifyListeners();

    int scanned = 0;
    try {
      for (final media in candidates) {
        if (!isUnlocked) break;
        try {
          Uint8List? bytes;
          if (isTelegramReady) {
            bytes = await downloadService.downloadAndDecrypt(media);
          } else {
            bytes = await loadEncryptedThumbnail(media);
          }

          if (bytes != null && bytes.isNotEmpty) {
            final thumbSvc = thumbnailService;
            var workingMedia = media;
            if (thumbSvc != null &&
                (media.localThumbPath == null ||
                    media.localThumbPath!.isEmpty ||
                    !File(media.localThumbPath!).existsSync())) {
              final thumbPath = await thumbSvc.generateAndSaveFromBytes(
                mediaId: media.id,
                plainImageBytes: bytes,
              );
              if (thumbPath != null && localDbService.isOpen) {
                workingMedia = media.copyWith(localThumbPath: thumbPath);
                await localDbService.saveMedia(workingMedia);
              }
            }

            await svc.scanAndGroupMedia(
              media: workingMedia,
              plainImageBytes: bytes,
            );
            scanned++;
            refreshVaultData();
          }
        } catch (e) {
          lastFaceScanError ??= e.toString();
        }

        faceScanDone++;
        notifyListeners();
      }

      if (scanned > 0) {
        await svc.consolidateClusters();
        refreshVaultData();
        _scheduleAutoIndexBackup();
      }
      return scanned;
    } finally {
      isScanningFaces = false;
      faceScanDone = 0;
      faceScanTotal = 0;
      notifyListeners();
    }
  }

  Future<void> renamePerson(String clusterId, String newName) async {
    final svc = faceGroupingService;
    if (svc == null || !isUnlocked) return;
    await svc.renameCluster(clusterId, newName);
    refreshVaultData();
    _scheduleAutoIndexBackup();
  }

  Future<void> mergePersons({
    required String sourceClusterId,
    required String targetClusterId,
  }) async {
    final svc = faceGroupingService;
    if (svc == null || !isUnlocked) return;
    await svc.mergeClusters(
      sourceClusterId: sourceClusterId,
      targetClusterId: targetClusterId,
    );
    refreshVaultData();
    _scheduleAutoIndexBackup();
  }

  /// Generates encrypted local `.vthumb` previews for restored/older photos.
  Future<int> buildMissingThumbnails({int maxCount = 30}) async {
    final svc = thumbnailService;
    if (svc == null || !isUnlocked || !isTelegramReady || isBuildingThumbnails) {
      return 0;
    }

    final candidates = localDbService
        .getAllMedia()
        .where((m) {
          final isImage = !isVideoFile(m);
          final hasCloud =
              m.chunkMessageIds.isNotEmpty || m.backupMessageIds.isNotEmpty;
          final missingLocal = m.localThumbPath == null ||
              m.localThumbPath!.isEmpty ||
              !File(m.localThumbPath!).existsSync();
          return isImage && hasCloud && missingLocal;
        })
        .take(maxCount)
        .toList();

    if (candidates.isEmpty) return 0;

    isBuildingThumbnails = true;
    notifyListeners();

    int created = 0;
    try {
      for (final media in candidates) {
        if (!isUnlocked || !isTelegramReady) break;
        try {
          final plain = await downloadService.downloadAndDecrypt(media);
          final thumbPath = await svc.generateAndSaveFromBytes(
            mediaId: media.id,
            plainImageBytes: plain,
          );
          if (thumbPath != null && localDbService.isOpen) {
            await localDbService.saveMedia(
              media.copyWith(localThumbPath: thumbPath),
            );
            created++;
            refreshVaultData();
          }
        } catch (_) {}
      }
      return created;
    } finally {
      isBuildingThumbnails = false;
      notifyListeners();
    }
  }

  Future<void> init({String? hiveCustomPath}) async {
    if (isInitialized) return;
    await localDbService.init(customPath: hiveCustomPath);
    if (hiveCustomPath == null) {
      try {
        await autoBackupService?.init();
      } catch (_) {}
    }
    isInitialized = true;
    notifyListeners();
    if (hiveCustomPath == null) {
      unawaited(uploadService.cleanupStaleTempFiles());
      unawaited(tryAutoConnectTelegram());
    }
  }

  Future<void> tryAutoConnectTelegram() async {
    if (telegramService.isReady) return;
    try {
      final creds = await telegramService.getSavedApiCredentials();
      if (creds == null) return;
      final docsDir = await getApplicationDocumentsDirectory();
      final dbDir = '${docsDir.path}${Platform.pathSeparator}tdlib_db';
      final filesDir = '${docsDir.path}${Platform.pathSeparator}tdlib_files';
      await telegramService.start(
        databaseDirectory: dbDir,
        filesDirectory: filesDir,
        credentials: creds,
      );
    } catch (_) {}
  }

  Future<void> _onVaultUnlockedSyncAutoBackup() async {
    final auto = autoBackupService;
    if (auto == null || !isUnlocked) return;
    try {
      final absorbed = await auto.absorbSealedQueueIfUnlocked();
      if (absorbed > 0) {
        refreshVaultData();
        _scheduleAutoIndexBackup();
      }
      await auto.syncVaultContext(
        primaryChatId: primaryChannel?.chatId,
        backupChatId: backupChannel?.chatId,
        dbHashes: localDbService.getAllContentHashes(),
      );
    } catch (_) {}
  }

  Future<bool> isVaultSetup() => authService.isVaultSetup();

  Future<bool> hasRecoveryKey() => authService.hasRecoveryKey();

  Future<bool> isBiometricAvailable() => authService.isBiometricAvailable();

  Future<bool> isBiometricEnabled() => authService.isBiometricEnabled();

  void clearPendingRecoverySecrets() {
    pendingRecoveryKey = null;
    pendingWipeCode = null;
    notifyListeners();
  }

  Future<void> setBiometricEnabled(bool enable) async {
    lastError = null;
    if (enable) {
      await authService.enableBiometricUnlock();
    } else {
      await authService.disableBiometricUnlock();
    }
    notifyListeners();
  }

  Future<String> setupMasterPassword(String password) async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final recoveryKey = await authService.setupMasterPassword(password);
      final wipeCode = await authService.getOrCreateWipeCode();
      pendingRecoveryKey = recoveryKey;
      pendingWipeCode = wipeCode;

      isDecoyMode = false;
      final keyBytes = await cryptoService.exportMasterKeyBytes();
      await localDbService.open(keyBytes, decoy: false);
      refreshVaultData();
      unawaited(_onVaultUnlockedSyncAutoBackup());
      return recoveryKey;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> unlockWithPassword(String password) async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final mode = await authService.unlockWithPasswordMode(password);
      if (mode == UnlockMode.none) {
        lastError = 'Incorrect password.';
        return false;
      }
      isDecoyMode = mode == UnlockMode.decoy;
      final keyBytes = await cryptoService.exportMasterKeyBytes();
      try {
        await localDbService.open(keyBytes, decoy: isDecoyMode);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }
      refreshVaultData();
      if (!isDecoyMode) {
        unawaited(tryAutoConnectTelegram());
        unawaited(_onVaultUnlockedSyncAutoBackup());
      }
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> unlockWithBiometrics() async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      if (!await authService.isBiometricEnabled()) {
        lastError =
            'Biometric unlock is off. Unlock with your password and enable it in Settings.';
        return false;
      }

      final ok = await authService.unlockWithBiometrics();
      if (!ok) {
        lastError = 'Biometric unlock failed.';
        return false;
      }
      isDecoyMode = false;
      final keyBytes = await cryptoService.exportMasterKeyBytes();
      await localDbService.open(keyBytes, decoy: false);
      refreshVaultData();
      unawaited(tryAutoConnectTelegram());
      unawaited(_onVaultUnlockedSyncAutoBackup());
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final ok = await authService.changeMasterPassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      if (!ok) {
        lastError =
            'Current password is incorrect or new password is under 8 characters.';
      } else if (isTelegramReady && primaryChannel != null) {
        unawaited(backupCloudKeyBundle().catchError((_) => 0));
      }
      return ok;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> recoverVaultWithKey({
    required String recoveryKey,
    required String newPassword,
  }) async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final ok = await authService.recoverWithRecoveryKey(
        recoveryKey: recoveryKey,
        newPassword: newPassword,
      );
      if (!ok) {
        lastError = 'Invalid recovery key or not configured for this vault.';
        return false;
      }
      isDecoyMode = false;
      final keyBytes = await cryptoService.exportMasterKeyBytes();
      await localDbService.open(keyBytes, decoy: false);
      refreshVaultData();
      unawaited(tryAutoConnectTelegram());
      unawaited(_onVaultUnlockedSyncAutoBackup());
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<String> regenerateRecoveryKey() async {
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final key = await authService.regenerateRecoveryKey();
      pendingRecoveryKey = key;
      pendingWipeCode = await authService.getOrCreateWipeCode();
      if (isTelegramReady && primaryChannel != null) {
        unawaited(backupCloudKeyBundle().catchError((_) => 0));
      }
      return key;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<int> backupCloudKeyBundle() async {
    final service = indexBackupService;
    if (service == null) {
      throw StateError('Cloud sync service is not initialized.');
    }

    lastError = null;
    isSyncingKeyBundle = true;
    notifyListeners();
    try {
      final bundleJson = await authService.exportCloudKeyBundleJson();
      final msgId = await service.backupKeyBundle(bundleJson);
      lastKeyBundleSyncAt = DateTime.now();
      return msgId;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isSyncingKeyBundle = false;
      notifyListeners();
    }
  }

  Future<IndexBackupResult?> restoreCloudVaultFromTelegram({
    required VaultChannel channel,
    required String password,
    String? recoveryKey,
  }) async {
    final service = indexBackupService;
    if (service == null) {
      throw StateError('Cloud sync service is not initialized.');
    }

    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      final bundleJson =
          await service.downloadLatestKeyBundle(chatId: channel.chatId);
      await authService.importCloudKeyBundleJson(bundleJson);

      final bool unlocked;
      final usingRecovery =
          recoveryKey != null && recoveryKey.trim().isNotEmpty;
      if (usingRecovery) {
        unlocked = await authService.recoverWithRecoveryKey(
          recoveryKey: recoveryKey.trim(),
          newPassword: password,
        );
      } else {
        unlocked = await authService.unlockWithPassword(password);
      }

      if (!unlocked) {
        await authService.wipeAuthData();
        lastError = usingRecovery
            ? 'Invalid 24-char recovery key or new password is under 8 chars.'
            : 'Incorrect master password for this cloud vault.';
        return null;
      }

      await authService.getOrCreateWipeCode();
      final keyBytes = await cryptoService.exportMasterKeyBytes();
      await localDbService.open(keyBytes);

      final restored = await service.restoreLatestIndex(chatId: channel.chatId);
      lastIndexBackupAt = restored.timestamp;

      if (channelService.getPrimaryChannel() == null) {
        await channelService.setPrimaryChannel(channel);
      }

      refreshVaultData();
      unawaited(_onVaultUnlockedSyncAutoBackup());

      if (usingRecovery) {
        unawaited(backupCloudKeyBundle().catchError((_) => 0));
      }

      return restored;
    } catch (e) {
      if (!isUnlocked) {
        await authService.wipeAuthData();
      }
      lastError = e.toString();
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<IndexBackupResult> backupCloudIndex() async {
    final service = indexBackupService;
    if (service == null) {
      throw StateError('Cloud index backup service is not initialized.');
    }

    lastError = null;
    isSyncingIndex = true;
    notifyListeners();
    try {
      final result = await service.backupIndex();
      lastIndexBackupAt = result.timestamp;
      return result;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isSyncingIndex = false;
      notifyListeners();
    }
  }

  Future<IndexBackupResult> restoreCloudIndex({int? chatId}) async {
    final service = indexBackupService;
    if (service == null) {
      throw StateError('Cloud index backup service is not initialized.');
    }

    lastError = null;
    isSyncingIndex = true;
    notifyListeners();
    try {
      final result = await service.restoreLatestIndex(chatId: chatId);
      lastIndexBackupAt = result.timestamp;
      refreshVaultData();
      return result;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isSyncingIndex = false;
      notifyListeners();
    }
  }

  void _scheduleAutoIndexBackup() {
    if (isDecoyMode ||
        indexBackupService == null ||
        !isUnlocked ||
        !isTelegramReady ||
        primaryChannel == null) {
      return;
    }
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer(const Duration(seconds: 5), () async {
      if (!isUnlocked || !isTelegramReady || isSyncingIndex) return;
      try {
        await backupCloudIndex();
      } catch (_) {}
    });
  }

  Future<void> lockVault() async {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
    isDecoyMode = false;
    isBusy = false;
    isScanningFaces = false;
    isBuildingThumbnails = false;
    pendingRecoveryKey = null;
    pendingWipeCode = null;
    downloadService.clearRamCache();
    thumbnailService?.clearRamCache();
    faceGroupingService?.clearRamCache();
    unawaited(uploadService.cleanupStaleTempFiles());
    authService.lock();
    await localDbService.close();
    mediaItems = const [];
    channels = const [];
    faceClusters = const [];
    notifyListeners();
  }

  void refreshVaultData() {
    if (!localDbService.isOpen) return;
    mediaItems = localDbService.getAllMedia(
      album: selectedAlbum,
      onlyFavorites: onlyFavorites,
    );
    channels = channelService.getSavedChannels();
    faceClusters = localDbService.getAllFaceClusters();
    final auto = autoBackupService;
    if (auto != null && !isDecoyMode) {
      unawaited(
        auto.syncVaultContext(
          primaryChatId: primaryChannel?.chatId,
          backupChatId: backupChannel?.chatId,
          dbHashes: localDbService.getAllContentHashes(),
        ),
      );
    }
    notifyListeners();
  }

  void setFilter({String? album, bool? favoritesOnly}) {
    if (album != null) selectedAlbum = album;
    if (favoritesOnly != null) onlyFavorites = favoritesOnly;
    refreshVaultData();
  }

  Future<VaultMedia> uploadMediaFile({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? album,
    bool skipIfDuplicate = true,
  }) async {
    lastError = null;
    isBusy = true;
    operationProgress = 0.0;
    notifyListeners();
    try {
      if (isDecoyMode) {
        return await _saveLocalDecoyMediaFromFile(
          filePath: filePath,
          fileName: fileName,
          mimeType: mimeType,
          album: album ?? (selectedAlbum == 'All' ? 'Camera' : selectedAlbum),
        );
      }
      var item = await uploadService.uploadFileStream(
        filePath: filePath,
        fileName: fileName,
        mimeType: mimeType,
        album: album ?? (selectedAlbum == 'All' ? 'Camera' : selectedAlbum),
        skipIfDuplicate: skipIfDuplicate,
        onProgress: (p) {
          operationProgress = p;
          notifyListeners();
        },
      );

      final thumbSvc = thumbnailService;
      if (thumbSvc != null) {
        try {
          final thumbPath = await thumbSvc.generateAndSaveFromFile(
            mediaId: item.id,
            filePath: filePath,
            mimeType: mimeType,
          );
          if (thumbPath != null && localDbService.isOpen) {
            item = item.copyWith(localThumbPath: thumbPath);
            await localDbService.saveMedia(item);
          }
        } catch (_) {}
      }

      if (!isVideoFile(item)) {
        final faceSvc = faceGroupingService;
        if (faceSvc != null) {
          try {
            final fileBytes = await File(filePath).readAsBytes();
            item = await faceSvc.scanAndGroupMedia(
              media: item,
              plainImageBytes: fileBytes,
              existingLocalFilePath: filePath,
            );
          } catch (_) {}
        }
      }

      refreshVaultData();
      _scheduleAutoIndexBackup();
      return item;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<VaultMedia> uploadPhoto({
    required Uint8List plainBytes,
    required String fileName,
    required String mimeType,
    String? album,
    bool skipIfDuplicate = true,
  }) async {
    lastError = null;
    isBusy = true;
    operationProgress = 0.0;
    notifyListeners();
    try {
      if (isDecoyMode) {
        return await _saveLocalDecoyMediaFromBytes(
          plainBytes: plainBytes,
          fileName: fileName,
          mimeType: mimeType,
          album: album ?? (selectedAlbum == 'All' ? 'Camera' : selectedAlbum),
        );
      }
      var item = await uploadService.uploadMedia(
        plainBytes: plainBytes,
        fileName: fileName,
        mimeType: mimeType,
        album: album ?? (selectedAlbum == 'All' ? 'Camera' : selectedAlbum),
        skipIfDuplicate: skipIfDuplicate,
        onProgress: (p) {
          operationProgress = p;
          notifyListeners();
        },
      );

      if (!isVideoFile(item)) {
        final thumbSvc = thumbnailService;
        if (thumbSvc != null) {
          try {
            final thumbPath = await thumbSvc.generateAndSaveFromBytes(
              mediaId: item.id,
              plainImageBytes: plainBytes,
            );
            if (thumbPath != null && localDbService.isOpen) {
              item = item.copyWith(localThumbPath: thumbPath);
              await localDbService.saveMedia(item);
            }
          } catch (_) {}
        }

        final faceSvc = faceGroupingService;
        if (faceSvc != null) {
          try {
            item = await faceSvc.scanAndGroupMedia(
              media: item,
              plainImageBytes: plainBytes,
            );
          } catch (_) {}
        }
      }

      refreshVaultData();
      _scheduleAutoIndexBackup();
      return item;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Foreground decrypt for currently viewed media (updates progress bar).
  Future<Uint8List> loadDecryptedBytes(VaultMedia media) async {
    lastError = null;
    operationProgress = 0.0;
    notifyListeners();
    try {
      if (isDecoyMode ||
          (media.localEncryptedPath != null &&
              media.localEncryptedPath!.isNotEmpty &&
              media.chunkMessageIds.isEmpty)) {
        return await _decryptLocalDecoyBytes(media);
      }
      final bytes = await downloadService.downloadAndDecrypt(
        media,
        onProgress: (p) {
          operationProgress = p;
          notifyListeners();
        },
      );
      _maybeBuildThumbnailInBackground(media, bytes);
      return bytes;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    }
  }

  /// Silent background decrypt for [-2, -1, +1, +2] sliding prefetch window.
  /// Does not clobber foreground progress or spam notifyListeners().
  Future<Uint8List?> prefetchDecryptedBytes(VaultMedia media) async {
    if (!isUnlocked || isVideoFile(media)) return null;
    if (isDecoyMode) {
      try {
        return await _decryptLocalDecoyBytes(media);
      } catch (_) {
        return null;
      }
    }
    if (!isTelegramReady) return null;
    final cached = downloadService.getCachedBytes(media.id);
    if (cached != null) return cached;
    try {
      if (isDecoyMode ||
          (media.localEncryptedPath != null &&
              media.localEncryptedPath!.isNotEmpty &&
              media.chunkMessageIds.isEmpty)) {
        return await _decryptLocalDecoyBytes(media);
      }
      final bytes = await downloadService.downloadAndDecrypt(media);
      _maybeBuildThumbnailInBackground(media, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _maybeBuildThumbnailInBackground(VaultMedia media, Uint8List bytes) {
    final thumbSvc = thumbnailService;
    if (thumbSvc == null ||
        isVideoFile(media) ||
        thumbSvc.getCachedThumb(media.id) != null) {
      return;
    }
    final missingDisk = media.localThumbPath == null ||
        media.localThumbPath!.isEmpty ||
        !File(media.localThumbPath!).existsSync();
    if (!missingDisk) return;

    unawaited(() async {
      try {
        final thumbPath = await thumbSvc.generateAndSaveFromBytes(
          mediaId: media.id,
          plainImageBytes: bytes,
        );
        if (thumbPath != null && localDbService.isOpen) {
          final latest = localDbService.getMedia(media.id) ?? media;
          await localDbService.saveMedia(
            latest.copyWith(localThumbPath: thumbPath),
          );
          refreshVaultData();
        }
      } catch (_) {}
    }());
  }

  Future<void> _ensureVideoThumbnailFromFile(
    VaultMedia media,
    String videoFilePath,
  ) async {
    final thumbSvc = thumbnailService;
    if (thumbSvc == null || !isUnlocked) return;
    if (thumbSvc.getCachedThumb(media.id) != null) return;
    final hasLocal = media.localThumbPath != null &&
        media.localThumbPath!.isNotEmpty &&
        File(media.localThumbPath!).existsSync();
    if (hasLocal) return;

    try {
      final thumbPath = await thumbSvc.generateAndSaveFromVideoFile(
        mediaId: media.id,
        filePath: videoFilePath,
      );
      if (thumbPath != null && localDbService.isOpen) {
        final latest = localDbService.getMedia(media.id) ?? media;
        await localDbService.saveMedia(
          latest.copyWith(localThumbPath: thumbPath),
        );
        refreshVaultData();
      }
    } catch (_) {}
  }

  Future<File> downloadVideoToFile(VaultMedia media, File targetFile) async {
    lastError = null;
    operationProgress = 0.0;
    notifyListeners();
    try {
      if (isDecoyMode ||
          (media.localEncryptedPath != null &&
              media.localEncryptedPath!.isNotEmpty &&
              media.chunkMessageIds.isEmpty)) {
        final plain = await _decryptLocalDecoyBytes(media);
        await targetFile.writeAsBytes(plain, flush: true);
        await _ensureVideoThumbnailFromFile(media, targetFile.path);
        operationProgress = 1.0;
        notifyListeners();
        return targetFile;
      }
      final file = await downloadService.downloadAndDecryptToFile(
        media,
        targetFile,
        onProgress: (p) {
          operationProgress = p;
          notifyListeners();
        },
      );
      await _ensureVideoThumbnailFromFile(media, file.path);
      return file;
    } catch (e) {
      lastError = e.toString();
      rethrow;
    }
  }

  Future<void> toggleFavorite(VaultMedia media) async {
    if (!localDbService.isOpen) return;
    await localDbService.saveMedia(media.copyWith(isFavorite: !media.isFavorite));
    refreshVaultData();
    _scheduleAutoIndexBackup();
  }

  Future<void> deleteMediaRecord(String mediaId) async {
    if (!localDbService.isOpen) return;
    final existing = localDbService.getMedia(mediaId);
    await localDbService.deleteMedia(mediaId);
    if (existing?.localEncryptedPath != null &&
        existing!.localEncryptedPath!.isNotEmpty) {
      try {
        final f = File(existing.localEncryptedPath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await thumbnailService?.deleteThumb(
      mediaId,
      customPath: existing?.localThumbPath,
    );
    refreshVaultData();
    _scheduleAutoIndexBackup();
  }

  // ---------------- DECOY VAULT HELPERS ----------------

  static const int _maxDecoyLocalFileBytes = 50 * 1024 * 1024; // 50 MB guard

  Future<bool> hasDecoyPassword() => authService.hasDecoyPassword();

  Future<void> setupDecoyPassword(String decoyPassword) async {
    if (isDecoyMode) {
      throw StateError('Unavailable in current session.');
    }
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      await _wipeDecoyFilesOnly();
      await localDbService.wipeDecoyBoxes();
      await authService.setupDecoyPassword(decoyPassword);
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> removeDecoyPassword() async {
    if (isDecoyMode) return;
    lastError = null;
    isBusy = true;
    notifyListeners();
    try {
      await _wipeDecoyFilesOnly();
      await localDbService.wipeDecoyBoxes();
      await authService.removeDecoyPassword();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Safe decoy-only panic wipe: wipes decoy files & decoy DB while keeping real vault 100% intact.
  Future<void> wipeOnlyDecoySession() async {
    await lockVault();
    await _wipeDecoyFilesOnly();
    await localDbService.wipeDecoyBoxes();
    notifyListeners();
  }

  Future<Directory> _resolveDecoyMediaDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docsDir.path}${Platform.pathSeparator}vault_decoy_media',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _wipeDecoyFilesOnly() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final decoyDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_decoy_media',
      );
      if (await decoyDir.exists()) {
        await decoyDir.delete(recursive: true);
      }
      final thumbDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_thumbs',
      );
      if (await thumbDir.exists()) {
        await for (final entity in thumbDir.list()) {
          if (entity is File &&
              entity.path.split(Platform.pathSeparator).last.startsWith('decoy_')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<VaultMedia> _saveLocalDecoyMediaFromFile({
    required String filePath,
    required String fileName,
    required String mimeType,
    required String album,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Selected file could not be read.');
    }
    final size = await file.length();
    if (size > _maxDecoyLocalFileBytes) {
      throw StateError('Local offline files are limited to 50 MB.');
    }
    final plainBytes = await file.readAsBytes();
    return _saveLocalDecoyMediaFromBytes(
      plainBytes: plainBytes,
      fileName: fileName,
      mimeType: mimeType,
      album: album,
    );
  }

  Future<VaultMedia> _saveLocalDecoyMediaFromBytes({
    required Uint8List plainBytes,
    required String fileName,
    required String mimeType,
    required String album,
  }) async {
    if (plainBytes.length > _maxDecoyLocalFileBytes) {
      throw StateError('Local offline files are limited to 50 MB.');
    }
    final mediaId = 'decoy_${DateTime.now().microsecondsSinceEpoch}';
    final dir = await _resolveDecoyMediaDir();
    final encFile = File('${dir.path}${Platform.pathSeparator}$mediaId.vdecoy');

    operationProgress = 0.35;
    notifyListeners();
    final encrypted = await cryptoService.encrypt(plainBytes);
    await encFile.writeAsBytes(encrypted, flush: true);

    String? thumbPath;
    if (!mimeType.toLowerCase().startsWith('video/')) {
      try {
        thumbPath = await thumbnailService?.generateAndSaveFromBytes(
          mediaId: mediaId,
          plainImageBytes: plainBytes,
        );
      } catch (_) {}
    }

    final item = VaultMedia(
      id: mediaId,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: plainBytes.length,
      createdAt: DateTime.now(),
      album: album,
      uploadStatus: 'uploaded',
      localEncryptedPath: encFile.path,
      localThumbPath: thumbPath,
      facesScanned: true,
    );
    await localDbService.saveMedia(item);
    operationProgress = 1.0;
    refreshVaultData();
    return item;
  }

  Future<Uint8List> _decryptLocalDecoyBytes(VaultMedia media) async {
    final path = media.localEncryptedPath;
    if (path == null || path.isEmpty) {
      throw StateError('Local encrypted file missing.');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Local encrypted file not found on device.');
    }
    final encBytes = await file.readAsBytes();
    operationProgress = 0.6;
    notifyListeners();
    final plain = await cryptoService.decrypt(encBytes);
    operationProgress = 1.0;
    notifyListeners();
    return plain;
  }

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    _telegramAuthSub?.cancel();
    autoBackupService?.dispose();
    unawaited(faceGroupingService?.dispose());
    super.dispose();
  }
}