import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_gallery/data/models/vault_media.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';
import 'package:vault_gallery/data/services/download_service.dart';
import 'package:vault_gallery/data/services/tdlib_transport.dart';
import 'package:vault_gallery/data/services/telegram_service.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeDownloadTransport implements TdlibTransport {
  final Directory tdlibCacheDir;
  final _controller = StreamController<JsonMap>.broadcast();

  // Key: "$chatId:$messageId" -> fileId
  final Map<String, int> messageToFileId = {};
  // Key: fileId -> encrypted chunk bytes
  final Map<int, Uint8List> serverFiles = {};
  final Set<int> deletedFileIds = {};
  int getMessageCallCount = 0;
  bool failPrimaryChat = false;
  int _nextFileId = 1000;

  _FakeDownloadTransport(this.tdlibCacheDir);

  int putChunkOnServer(int chatId, int messageId, Uint8List encryptedChunk) {
    final fileId = _nextFileId++;
    messageToFileId['$chatId:$messageId'] = fileId;
    serverFiles[fileId] = encryptedChunk;
    return fileId;
  }

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
    } else if (type == 'getMessage') {
      getMessageCallCount++;
      final chatId = (request['chat_id'] as num).toInt();
      final msgId = (request['message_id'] as num).toInt();

      if (failPrimaryChat && chatId == -1001111111) {
        _emit({
          '@type': 'error',
          'code': 404,
          'message': 'MESSAGE_NOT_FOUND',
          '@extra': extra,
        });
        return;
      }

      final fileId = messageToFileId['$chatId:$msgId'];
      if (fileId == null) {
        _emit({
          '@type': 'error',
          'code': 404,
          'message': 'NOT_FOUND',
          '@extra': extra,
        });
        return;
      }

      _emit({
        '@type': 'message',
        'id': msgId,
        'content': {
          '@type': 'messageDocument',
          'document': {
            '@type': 'document',
            'document': {'@type': 'file', 'id': fileId},
          },
        },
        '@extra': extra,
      });
    } else if (type == 'downloadFile') {
      final fileId = (request['file_id'] as num).toInt();
      final bytes = serverFiles[fileId]!;
      final file = File(
        '${tdlibCacheDir.path}${Platform.pathSeparator}chunk_$fileId.vaul',
      );
      file.writeAsBytesSync(bytes, flush: true);

      _emit({
        '@type': 'file',
        'id': fileId,
        'local': {
          '@type': 'localFile',
          'path': file.path,
          'is_downloading_completed': true,
        },
        '@extra': extra,
      });
    } else if (type == 'deleteFile') {
      final fileId = (request['file_id'] as num).toInt();
      deletedFileIds.add(fileId);
      final file = File(
        '${tdlibCacheDir.path}${Platform.pathSeparator}chunk_$fileId.vaul',
      );
      if (file.existsSync()) {
        file.deleteSync();
      }
      _emit({'@type': 'ok', '@extra': extra});
    }
  }

  @override
  Future<void> stop() async {
    await _controller.close();
  }
}

void main() {
  late Directory tempDir;
  late CryptoService crypto;
  late TelegramService tg;
  late _FakeDownloadTransport transport;
  late DownloadService downloadService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_download_test_');

    crypto = CryptoService();
    final salt = crypto.generateSalt();
    await crypto.deriveKey('DownloadSecret#1', salt);

    transport = _FakeDownloadTransport(tempDir);
    tg = TelegramService(transport: transport, credentialStore: _InMemoryStore());
    await tg.saveApiCredentials(12345, 'dummy_hash');
    final ready = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.ready);
    await tg.start(databaseDirectory: tempDir.path, filesDirectory: tempDir.path);
    await ready;

    downloadService = DownloadService(
      cryptoService: crypto,
      telegramService: tg,
    );
  });

  tearDown(() async {
    downloadService.clearRamCache();
    await tg.dispose();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('Downloads multi-chunk encrypted file, decrypts strictly in RAM, and cleans disk cache', () async {
    final originalPhoto = Uint8List.fromList(List.generate(250, (i) => (i * 7) % 256));
    final encrypted = await crypto.encrypt(originalPhoto);

    // Encrypted data ko 3 chunks mein tod kar fake Telegram Primary channel par rakho
    final chunk1 = Uint8List.sublistView(encrypted, 0, 100);
    final chunk2 = Uint8List.sublistView(encrypted, 100, 200);
    final chunk3 = Uint8List.sublistView(encrypted, 200);

    transport.putChunkOnServer(-1001111111, 501, chunk1);
    transport.putChunkOnServer(-1001111111, 502, chunk2);
    transport.putChunkOnServer(-1001111111, 503, chunk3);

    final media = VaultMedia(
      id: 'photo_1',
      fileName: 'secret.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: originalPhoto.length,
      createdAt: DateTime.now(),
      uploadStatus: 'uploaded',
      primaryChatId: -1001111111,
      chunkMessageIds: [501, 502, 503],
    );

    final progressEvents = <double>[];
    final decrypted = await downloadService.downloadAndDecrypt(
      media,
      onProgress: progressEvents.add,
    );

    expect(decrypted, originalPhoto);
    expect(progressEvents.last, 1.0);
    // Disk par koi bhi file (na encrypted chunk, na plaintext) nahi bachni chahiye
    expect(tempDir.listSync(), isEmpty);
    expect(transport.deletedFileIds.length, 3);
  });

  test('Falls back to Backup Channel automatically if Primary Channel fails', () async {
    final originalPhoto = Uint8List.fromList([11, 22, 33, 44, 55, 66, 77]);
    final encrypted = await crypto.encrypt(originalPhoto);

    // Sirf Backup Channel par chunk rakho aur Primary ko fail karao
    transport.failPrimaryChat = true;
    transport.putChunkOnServer(-1002222222, 901, encrypted);

    final media = VaultMedia(
      id: 'photo_backup',
      fileName: 'recovered.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: originalPhoto.length,
      createdAt: DateTime.now(),
      uploadStatus: 'uploaded',
      primaryChatId: -1001111111,
      chunkMessageIds: [501],
      backupChatId: -1002222222,
      backupMessageIds: [901],
    );

    final decrypted = await downloadService.downloadAndDecrypt(media);
    expect(decrypted, originalPhoto);
  });

  test('Serves repeat reads from RAM cache and zeroes memory on clearRamCache()', () async {
    final originalPhoto = Uint8List.fromList([9, 8, 7, 6, 5, 4]);
    final encrypted = await crypto.encrypt(originalPhoto);
    transport.putChunkOnServer(-1001111111, 601, encrypted);

    final media = VaultMedia(
      id: 'photo_cached',
      fileName: 'cached.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: originalPhoto.length,
      createdAt: DateTime.now(),
      uploadStatus: 'uploaded',
      primaryChatId: -1001111111,
      chunkMessageIds: [601],
    );

    final firstRead = await downloadService.downloadAndDecrypt(media);
    expect(transport.getMessageCallCount, 1);

    // Dusri baar RAM cache se aana chahiye (Telegram call count 1 hi rahega)
    final secondRead = await downloadService.downloadAndDecrypt(media);
    expect(transport.getMessageCallCount, 1);
    expect(secondRead, originalPhoto);
    expect(downloadService.currentRamCacheBytes, originalPhoto.length);

    // Lock hone par RAM zero-fill hona chahiye
    downloadService.clearRamCache();
    expect(downloadService.currentRamCacheBytes, 0);
    expect(downloadService.getCachedBytes('photo_cached'), isNull);
    expect(firstRead.every((b) => b == 0), isTrue);
  });
}