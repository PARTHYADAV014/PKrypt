import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/channel_service.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';
import 'package:vault_gallery/data/services/download_service.dart';
import 'package:vault_gallery/data/services/local_db_service.dart';
import 'package:vault_gallery/data/services/tdlib_transport.dart';
import 'package:vault_gallery/data/services/telegram_service.dart';
import 'package:vault_gallery/data/services/upload_service.dart';
import 'package:vault_gallery/data/services/vault_controller.dart';
import 'package:vault_gallery/data/services/vault_providers.dart';
import 'package:vault_gallery/main.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, String> _data = {};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async => _data[key] = value;
  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _DummyTransport implements TdlibTransport {
  final _controller = StreamController<JsonMap>.broadcast();
  @override
  Stream<JsonMap> get updates => _controller.stream;
  @override
  Future<void> start() async {}
  @override
  void send(JsonMap request) {}
  @override
  Future<void> stop() async => _controller.close();
}

void main() {
  late Directory tempDir;
  late VaultController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_ui_test_');
    final crypto = CryptoService();
    final auth = AuthService(cryptoService: crypto, store: _InMemoryStore());
    final db = LocalDbService();
    final tg = TelegramService(
      transport: _DummyTransport(),
      credentialStore: _InMemoryStore(),
    );
    final channels = ChannelService(telegramService: tg, localDbService: db);
    final uploader = UploadService(
      cryptoService: crypto,
      telegramService: tg,
      localDbService: db,
      tempDirectoryPath: '${tempDir.path}${Platform.pathSeparator}tmp',
    );
    final downloader = DownloadService(
      cryptoService: crypto,
      telegramService: tg,
    );

    controller = VaultController(
      cryptoService: crypto,
      authService: auth,
      localDbService: db,
      telegramService: tg,
      channelService: channels,
      uploadService: uploader,
      downloadService: downloader,
    );
    await controller.init(hiveCustomPath: tempDir.path);
  });

  tearDown(() async {
    await controller.localDbService.close();
    await controller.telegramService.dispose();
    await Hive.close();
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('Fresh app routes Splash -> Setup Password', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultControllerProvider.overrideWith((ref) => controller),
        ],
        child: const VaultGalleryApp(),
      ),
    );

    expect(find.text('VaultGallery'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    expect(find.text('Create Master Password'), findsOneWidget);
  });

  testWidgets('Configured app routes Splash -> Unlock Screen', (tester) async {
    await tester.runAsync(() async {
      await controller.setupMasterPassword('VaultPass#2026');
      await controller.lockVault();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultControllerProvider.overrideWith((ref) => controller),
        ],
        child: const VaultGalleryApp(),
      ),
    );

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    expect(find.text('Unlock Vault'), findsOneWidget);
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Use Biometrics'), findsOneWidget);
  });
}