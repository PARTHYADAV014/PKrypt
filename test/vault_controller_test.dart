import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:vault_gallery/data/models/vault_channel.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/channel_service.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';
import 'package:vault_gallery/data/services/download_service.dart';
import 'package:vault_gallery/data/services/local_db_service.dart';
import 'package:vault_gallery/data/services/tdlib_transport.dart';
import 'package:vault_gallery/data/services/telegram_service.dart';
import 'package:vault_gallery/data/services/upload_service.dart';
import 'package:vault_gallery/data/services/vault_controller.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, String> _data = {};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async => _data[key] = value;
  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeVaultTransport implements TdlibTransport {
  final Directory cacheDir;
  final _controller = StreamController<JsonMap>.broadcast();
  final Map<String, int> msgToFile = {};
  final Map<int, Uint8List> files = {};
  int _tempId = 1;
  int _msgId = 700;
  int _fileId = 2000;

  _FakeVaultTransport(this.cacheDir);

  @override
  Stream<JsonMap> get updates => _controller.stream;

  @override
  Future<void> start() async {}

  void _emit(JsonMap event) {
    scheduleMicrotask(() {
      if (!_controller.isClosed) _controller.add(event);
    });
  }

  @override
  void send(JsonMap request) {
    final type = request['@type'];
    final extra = request['@extra'];

    if (type == 'getAuthorizationState') {
      _emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {'@type': 'authorizationStateReady'},
      });
    } else if (type == 'sendMessage') {
      final tId = _tempId++;
      final doc = (request['input_message_content'] as JsonMap)['document'] as JsonMap;
      final bytes = File(doc['path'] as String).readAsBytesSync();
      final sId = _msgId++;
      final fId = _fileId++;
      msgToFile['${request['chat_id']}:$sId'] = fId;
      files[fId] = bytes;

      _emit({
        '@type': 'message',
        'id': tId,
        'sending_state': {'@type': 'messageSendingStatePending'},
        '@extra': extra,
      });
      _emit({
        '@type': 'updateMessageSendSucceeded',
        'old_message_id': tId,
        'message': {'@type': 'message', 'id': sId},
      });
    } else if (type == 'getMessage') {
      final fId = msgToFile['${request['chat_id']}:${request['message_id']}']!;
      _emit({
        '@type': 'message',
        'id': request['message_id'],
        'content': {
          '@type': 'messageDocument',
          'document': {
            '@type': 'document',
            'document': {'@type': 'file', 'id': fId},
          },
        },
        '@extra': extra,
      });
    } else if (type == 'downloadFile') {
      final fId = (request['file_id'] as num).toInt();
      final f = File('${cacheDir.path}${Platform.pathSeparator}dl_$fId.vaul');
      f.writeAsBytesSync(files[fId]!, flush: true);
      _emit({
        '@type': 'file',
        'id': fId,
        'local': {
          '@type': 'localFile',
          'path': f.path,
          'is_downloading_completed': true,
        },
        '@extra': extra,
      });
    } else if (type == 'deleteFile') {
      _emit({'@type': 'ok', '@extra': extra});
    }
  }

  @override
  Future<void> stop() async => _controller.close();
}

void main() {
  late Directory tempDir;
  late VaultController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_ctrl_test_');
    final crypto = CryptoService();
    final auth = AuthService(cryptoService: crypto, store: _InMemoryStore());
    final db = LocalDbService();
    final transport = _FakeVaultTransport(tempDir);
    final tg = TelegramService(transport: transport, credentialStore: _InMemoryStore());
    await tg.saveApiCredentials(12345, 'hash');
    final ready = tg.authStatusStream.firstWhere((s) => s == TelegramAuthStatus.ready);
    await tg.start(databaseDirectory: tempDir.path, filesDirectory: tempDir.path);
    await ready;

    final channels = ChannelService(telegramService: tg, localDbService: db);
    final uploader = UploadService(
      cryptoService: crypto,
      telegramService: tg,
      localDbService: db,
      tempDirectoryPath: '${tempDir.path}${Platform.pathSeparator}tmp',
    );
    final downloader = DownloadService(cryptoService: crypto, telegramService: tg);

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
    await controller.setupMasterPassword('MasterPass@2026');
    await db.saveChannel(VaultChannel(
      chatId: -1001111111,
      title: 'Vault Channel',
      isPrimary: true,
      addedAt: DateTime.now(),
    ));
  });

  tearDown(() async {
    await controller.lockVault();
    await controller.telegramService.dispose();
    await Hive.close();
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('End-to-end UI flow: upload photo, lock vault, unlock, view decrypted bytes', () async {
    final photoBytes = Uint8List.fromList([10, 20, 30, 40, 50]);
    final uploaded = await controller.uploadPhoto(
      plainBytes: photoBytes,
      fileName: 'ui_test.jpg',
      mimeType: 'image/jpeg',
    );

    expect(controller.mediaItems.length, 1);
    await controller.toggleFavorite(uploaded);
    expect(controller.mediaItems.first.isFavorite, isTrue);

    // Lock aur wapas unlock karke photo wapas dekho
    await controller.lockVault();
    expect(controller.isUnlocked, isFalse);

    final unlocked = await controller.unlockWithPassword('MasterPass@2026');
    expect(unlocked, isTrue);
    expect(controller.mediaItems.length, 1);

    final decrypted = await controller.loadDecryptedBytes(controller.mediaItems.first);
    expect(decrypted, photoBytes);
  });
}