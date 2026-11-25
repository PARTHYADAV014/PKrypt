import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:vault_gallery/data/models/vault_channel.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';
import 'package:vault_gallery/data/services/local_db_service.dart';
import 'package:vault_gallery/data/services/tdlib_transport.dart';
import 'package:vault_gallery/data/services/telegram_service.dart';
import 'package:vault_gallery/data/services/upload_service.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeUploadTransport implements TdlibTransport {
  final _controller = StreamController<JsonMap>.broadcast();
  final Map<int, Uint8List> uploadedChunksByServerId = {};
  final List<JsonMap> forwardRequests = [];
  bool failNextUpload = false;

  int _nextTempId = 100;
  int _nextServerId = 5000;
  int _nextBackupId = 9000;

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
      final tempId = _nextTempId++;
      final content = request['input_message_content'] as JsonMap;
      final doc = content['document'] as JsonMap;
      final filePath = doc['path'] as String;

      // Upload hone se pehle disk par maujood encrypted chunk ko read karke store karo
      final bytes = File(filePath).readAsBytesSync();

      _emit({
        '@type': 'message',
        'id': tempId,
        'sending_state': {'@type': 'messageSendingStatePending'},
        '@extra': extra,
      });

      if (failNextUpload) {
        failNextUpload = false;
        _emit({
          '@type': 'updateMessageSendFailed',
          'old_message_id': tempId,
          'error': {'code': 500, 'message': 'NETWORK_LOST'},
        });
      } else {
        final serverId = _nextServerId++;
        uploadedChunksByServerId[serverId] = bytes;
        _emit({
          '@type': 'updateMessageSendSucceeded',
          'old_message_id': tempId,
          'message': {'@type': 'message', 'id': serverId},
        });
      }
    } else if (type == 'forwardMessages') {
      forwardRequests.add(request);
      final srcIds = (request['message_ids'] as List).cast<int>();
      final forwarded = srcIds
          .map((_) => {'@type': 'message', 'id': _nextBackupId++})
          .toList();

      _emit({
        '@type': 'messages',
        'total_count': forwarded.length,
        'messages': forwarded,
        '@extra': extra,
      });
    }
  }

  @override
  Future<void> stop() async {
    await _controller.close();
  }
}

void main() {
  late Directory tempDir;
  late Directory chunkTempDir;
  late CryptoService crypto;
  late LocalDbService db;
  late TelegramService tg;
  late _FakeUploadTransport transport;
  late UploadService uploadService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_upload_test_');
    chunkTempDir = Directory('${tempDir.path}${Platform.pathSeparator}chunks');

    crypto = CryptoService();
    final salt = crypto.generateSalt();
    await crypto.deriveKey('UploadSecret#1', salt);
    final keyBytes = await crypto.exportMasterKeyBytes();

    db = LocalDbService();
    await db.init(customPath: tempDir.path);
    await db.open(keyBytes);

    await db.saveChannel(VaultChannel(
      chatId: -1001111111,
      title: 'Vault Main',
      isPrimary: true,
      addedAt: DateTime.now(),
    ));
    await db.saveChannel(VaultChannel(
      chatId: -1002222222,
      title: 'Vault Backup',
      isBackup: true,
      addedAt: DateTime.now(),
    ));

    transport = _FakeUploadTransport();
    tg = TelegramService(transport: transport, credentialStore: _InMemoryStore());
    await tg.saveApiCredentials(12345, 'dummy_hash');
    final ready = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.ready);
    await tg.start(databaseDirectory: tempDir.path, filesDirectory: tempDir.path);
    await ready;

    // Test mein 100-byte chunks use kar rahe hain taaki multi-chunk splitting verify ho
    uploadService = UploadService(
      cryptoService: crypto,
      telegramService: tg,
      localDbService: db,
      tempDirectoryPath: chunkTempDir.path,
      chunkSizeBytes: 100,
    );
  });

  tearDown(() async {
    await tg.dispose();
    await db.close();
    await Hive.close();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('Encrypts, splits into chunks, uploads, forwards to backup, and cleans temp files', () async {
    // 250 bytes ka sample photo data -> encrypt hone ke baad ~283 bytes -> 3 chunks
    final originalPhoto = Uint8List.fromList(List.generate(250, (i) => i % 256));
    final progressValues = <double>[];

    final uploaded = await uploadService.uploadMedia(
      plainBytes: originalPhoto,
      fileName: 'vacation.jpg',
      mimeType: 'image/jpeg',
      album: 'Camera',
      onProgress: progressValues.add,
    );

    // 1. Metadata & Chunk IDs verify karo
    expect(uploaded.uploadStatus, 'uploaded');
    expect(uploaded.chunkMessageIds.length, 3);
    expect(uploaded.backupChatId, -1002222222);
    expect(uploaded.backupMessageIds.length, 3);
    expect(progressValues.last, 1.0);

    // 2. Hive mein save hua verify karo
    final savedInDb = db.getMedia(uploaded.id);
    expect(savedInDb?.uploadStatus, 'uploaded');
    expect(savedInDb?.chunkMessageIds, uploaded.chunkMessageIds);

    // 3. Server-side backup forwarding verify karo
    expect(transport.forwardRequests.length, 1);
    expect(transport.forwardRequests.first['from_chat_id'], -1001111111);
    expect(transport.forwardRequests.first['chat_id'], -1002222222);

    // 4. Uploaded chunks ko jod kar wapas decrypt karo — original photo exact milni chahiye!
    final reassembled = BytesBuilder();
    for (final msgId in uploaded.chunkMessageIds) {
      reassembled.add(transport.uploadedChunksByServerId[msgId]!);
    }
    final decrypted = await crypto.decrypt(reassembled.toBytes());
    expect(decrypted, originalPhoto);

    // 5. Temp folder bilkul saaf hona chahiye (koi leftover file nahi)
    expect(chunkTempDir.listSync(), isEmpty);
  });

  test('Uploads cleanly when no Backup Channel is configured', () async {
    await db.deleteChannel(-1002222222);

    final smallPhoto = Uint8List.fromList([1, 2, 3, 4, 5]);
    final uploaded = await uploadService.uploadMedia(
      plainBytes: smallPhoto,
      fileName: 'note.png',
      mimeType: 'image/png',
    );

    expect(uploaded.uploadStatus, 'uploaded');
    expect(uploaded.chunkMessageIds.length, 1);
    expect(uploaded.backupChatId, isNull);
    expect(uploaded.backupMessageIds, isEmpty);
    expect(transport.forwardRequests, isEmpty);
  });

  test('Marks media as failed and cleans temp files if Telegram upload fails', () async {
    transport.failNextUpload = true;
    final sample = Uint8List.fromList(List.generate(50, (i) => i));

    await expectLater(
      () => uploadService.uploadMedia(
        plainBytes: sample,
        fileName: 'broken.jpg',
        mimeType: 'image/jpeg',
        customId: 'fail_item_1',
      ),
      throwsA(isA<TelegramApiException>()),
    );

    expect(db.getMedia('fail_item_1')?.uploadStatus, 'failed');
    expect(db.getPendingUploads().length, 1);
    expect(chunkTempDir.listSync(), isEmpty);
  });
}