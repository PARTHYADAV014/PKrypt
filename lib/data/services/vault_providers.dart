import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
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
import 'vault_controller.dart';

/// Shared Riverpod provider for accessing VaultController across UI screens.
final vaultControllerProvider = ChangeNotifierProvider<VaultController>((ref) {
  throw UnimplementedError(
    'vaultControllerProvider must be overridden inside ProviderScope in main.dart.',
  );
});

/// Initializes all vault services and temporary directories on app launch.
Future<VaultController> createVaultController() async {
  final tempDir = await getTemporaryDirectory();
  final uploadTempPath = '${tempDir.path}${Platform.pathSeparator}vault_chunks';
  final indexTempPath = '${tempDir.path}${Platform.pathSeparator}vault_index';

  final crypto = CryptoService();
  final auth = AuthService(cryptoService: crypto);
  final db = LocalDbService();
  final telegram = TelegramService();
  final channels = ChannelService(
    telegramService: telegram,
    localDbService: db,
  );
  final uploader = UploadService(
    cryptoService: crypto,
    telegramService: telegram,
    localDbService: db,
    tempDirectoryPath: uploadTempPath,
  );
  final downloader = DownloadService(
    cryptoService: crypto,
    telegramService: telegram,
    maxRamCacheBytes: 96 * 1024 * 1024, // 96 MB for smooth [-2..+2] sliding window
  );
  final indexBackup = IndexBackupService(
    cryptoService: crypto,
    telegramService: telegram,
    localDbService: db,
    tempDirectoryPath: indexTempPath,
  );
  final autoBackup = AutoBackupService(
    cryptoService: crypto,
    authService: auth,
    localDbService: db,
    telegramService: telegram,
    uploadService: uploader,
  );
  final thumbnails = ThumbnailService(
    cryptoService: crypto,
  );
  final faceGrouping = FaceGroupingService(
    cryptoService: crypto,
    localDbService: db,
  );

  final controller = VaultController(
    cryptoService: crypto,
    authService: auth,
    localDbService: db,
    telegramService: telegram,
    channelService: channels,
    uploadService: uploader,
    downloadService: downloader,
    indexBackupService: indexBackup,
    autoBackupService: autoBackup,
    thumbnailService: thumbnails,
    faceGroupingService: faceGrouping,
  );

  await controller.init();
  return controller;
}