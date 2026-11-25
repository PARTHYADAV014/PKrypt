import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import '../models/vault_media.dart';
import 'crypto_service.dart';
import 'tdlib_transport.dart';
import 'telegram_service.dart';

class DownloadService {
  static const int defaultMaxRamCacheBytes = 50 * 1024 * 1024; // 50 MB RAM cache
  static const List<int> _vaulMagic = [0x56, 0x41, 0x55, 0x4C]; // "VAUL"
  static const List<int> _vgz1Magic = [0x56, 0x47, 0x5A, 0x31]; // "VGZ1"

  final CryptoService _crypto;
  final TelegramService _telegram;
  final int maxRamCacheBytes;

  final LinkedHashMap<String, Uint8List> _ramCache =
      LinkedHashMap<String, Uint8List>();
  final Set<int> _loadedChatIds = <int>{};
  int _currentRamCacheBytes = 0;

  DownloadService({
    required CryptoService cryptoService,
    required TelegramService telegramService,
    this.maxRamCacheBytes = defaultMaxRamCacheBytes,
  })  : _crypto = cryptoService,
        _telegram = telegramService;

  int get currentRamCacheBytes => _currentRamCacheBytes;

  Uint8List? getCachedBytes(String mediaId) {
    final existing = _ramCache.remove(mediaId);
    if (existing != null) {
      _ramCache[mediaId] = existing;
    }
    return existing;
  }

  /// Ensures TDLib has loaded [chatId] in the current session before calling
  /// `getMessage`, avoiding "Chat not found" errors after cold restarts.
  Future<void> _ensureChatLoaded(int chatId) async {
    if (_loadedChatIds.contains(chatId)) return;

    try {
      await _telegram.sendRequest({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      _loadedChatIds.add(chatId);
      return;
    } catch (_) {}

    // Populate TDLib chat cache and retry getChat once
    try {
      await _telegram.sendRequest({
        '@type': 'loadChats',
        'chat_list': {'@type': 'chatListMain'},
        'limit': 100,
      });
    } catch (_) {}

    try {
      await _telegram.sendRequest({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      _loadedChatIds.add(chatId);
    } catch (_) {}
  }

  /// Downloads encrypted chunks and decrypts in RAM (photos & small media).
  /// Auto-supports both legacy single-blob VAUL and new per-chunk VAUL / VGZ1.
  Future<Uint8List> downloadAndDecrypt(
    VaultMedia media, {
    void Function(double progress)? onProgress,
    bool forceRefresh = false,
    bool deleteTelegramDiskCache = true,
  }) async {
    if (!_crypto.isUnlocked) {
      throw StateError(
        'Vault is locked. Unlock the vault before viewing photos.',
      );
    }

    if (!forceRefresh) {
      final cached = getCachedBytes(media.id);
      if (cached != null) {
        onProgress?.call(1.0);
        return cached;
      }
    }

    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in.');
    }

    final hasPrimary =
        media.primaryChatId != null && media.chunkMessageIds.isNotEmpty;
    final hasBackup =
        media.backupChatId != null && media.backupMessageIds.isNotEmpty;

    if (!hasPrimary && !hasBackup) {
      throw StateError('No Telegram message IDs are saved for this photo.');
    }

    List<Uint8List> encryptedChunks;

    if (hasPrimary) {
      try {
        encryptedChunks = await _downloadEncryptedChunkList(
          chatId: media.primaryChatId!,
          messageIds: media.chunkMessageIds,
          onProgress: onProgress,
          deleteTelegramDiskCache: deleteTelegramDiskCache,
        );
      } catch (_) {
        if (!hasBackup) rethrow;
        encryptedChunks = await _downloadEncryptedChunkList(
          chatId: media.backupChatId!,
          messageIds: media.backupMessageIds,
          onProgress: onProgress,
          deleteTelegramDiskCache: deleteTelegramDiskCache,
        );
      }
    } else {
      encryptedChunks = await _downloadEncryptedChunkList(
        chatId: media.backupChatId!,
        messageIds: media.backupMessageIds,
        onProgress: onProgress,
        deleteTelegramDiskCache: deleteTelegramDiskCache,
      );
    }

    onProgress?.call(0.90);

    final plainBytes = await _decryptChunkList(
      encryptedChunks,
      hintPerChunk: media.isPerChunkEncrypted,
    );

    _putInRamCache(media.id, plainBytes);
    onProgress?.call(1.0);

    return plainBytes;
  }

  /// Streams large videos chunk-by-chunk directly into [targetFile] without
  /// holding the entire video in RAM. Flushes after every chunk.
  Future<File> downloadAndDecryptToFile(
    VaultMedia media,
    File targetFile, {
    void Function(double progress)? onProgress,
    bool deleteTelegramDiskCache = true,
  }) async {
    if (!_crypto.isUnlocked) {
      throw StateError('Vault is locked. Unlock before playing videos.');
    }
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in.');
    }

    final hasPrimary =
        media.primaryChatId != null && media.chunkMessageIds.isNotEmpty;
    final hasBackup =
        media.backupChatId != null && media.backupMessageIds.isNotEmpty;

    if (!hasPrimary && !hasBackup) {
      throw StateError('No Telegram message IDs are saved for this video.');
    }

    await targetFile.parent.create(recursive: true);

    // Stream chunk-by-chunk if per-chunk encrypted or single-chunk file
    final canStream = media.isPerChunkEncrypted ||
        (hasPrimary && media.chunkMessageIds.length == 1) ||
        (!hasPrimary && hasBackup && media.backupMessageIds.length == 1);

    if (!canStream) {
      final bytes = await downloadAndDecrypt(
        media,
        onProgress: onProgress,
        deleteTelegramDiskCache: deleteTelegramDiskCache,
      );
      await targetFile.writeAsBytes(bytes, flush: true);
      return targetFile;
    }

    Future<void> streamFrom(int chatId, List<int> messageIds) async {
      await _ensureChatLoaded(chatId);
      final sink = targetFile.openWrite();
      var completed = false;
      try {
        for (int i = 0; i < messageIds.length; i++) {
          final encChunk = await _downloadSingleChunk(
            chatId: chatId,
            messageId: messageIds[i],
            deleteTelegramDiskCache: deleteTelegramDiskCache,
          );
          onProgress?.call((i + 0.65) / messageIds.length);

          // Decrypts off the main thread in a background isolate
          final plainChunk = await _crypto.decrypt(encChunk);
          sink.add(plainChunk);
          await sink.flush();

          onProgress?.call((i + 1) / messageIds.length);
        }
        completed = true;
      } finally {
        await sink.close();
        if (!completed && await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (_) {}
        }
      }
    }

    if (hasPrimary) {
      try {
        await streamFrom(media.primaryChatId!, media.chunkMessageIds);
      } catch (_) {
        if (!hasBackup) rethrow;
        if (await targetFile.exists()) await targetFile.delete();
        await streamFrom(media.backupChatId!, media.backupMessageIds);
      }
    } else {
      await streamFrom(media.backupChatId!, media.backupMessageIds);
    }

    return targetFile;
  }

  Future<Uint8List> _decryptChunkList(
    List<Uint8List> chunks, {
    required bool hintPerChunk,
  }) async {
    if (chunks.isEmpty) return Uint8List(0);
    if (chunks.length == 1) {
      return _crypto.decrypt(chunks.first);
    }

    final perChunk = hintPerChunk || _startsWithVaultMagic(chunks[1]);
    if (perChunk) {
      final builder = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        final plain = await _crypto.decrypt(chunk);
        builder.add(plain);
      }
      return builder.takeBytes();
    }

    // Legacy single-blob VAUL split across multiple chunks
    final combined = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      combined.add(chunk);
    }
    return _crypto.decrypt(combined.takeBytes());
  }

  bool _startsWithVaultMagic(Uint8List data) {
    if (data.length < 4) return false;
    final isVaul = data[0] == _vaulMagic[0] &&
        data[1] == _vaulMagic[1] &&
        data[2] == _vaulMagic[2] &&
        data[3] == _vaulMagic[3];
    if (isVaul) return true;
    return data[0] == _vgz1Magic[0] &&
        data[1] == _vgz1Magic[1] &&
        data[2] == _vgz1Magic[2] &&
        data[3] == _vgz1Magic[3];
  }

  Future<List<Uint8List>> _downloadEncryptedChunkList({
    required int chatId,
    required List<int> messageIds,
    required bool deleteTelegramDiskCache,
    void Function(double progress)? onProgress,
  }) async {
    await _ensureChatLoaded(chatId);
    final chunks = <Uint8List>[];

    for (int i = 0; i < messageIds.length; i++) {
      final chunkBytes = await _downloadSingleChunk(
        chatId: chatId,
        messageId: messageIds[i],
        deleteTelegramDiskCache: deleteTelegramDiskCache,
      );
      chunks.add(chunkBytes);

      final fraction = (i + 1) / messageIds.length;
      onProgress?.call(fraction * 0.85);
    }

    return chunks;
  }

  Future<Uint8List> _downloadSingleChunk({
    required int chatId,
    required int messageId,
    required bool deleteTelegramDiskCache,
  }) async {
    await _ensureChatLoaded(chatId);

    var reloadedChat = false;
    final messageResp = await _withRetry(() async {
      try {
        return await _telegram.sendRequest({
          '@type': 'getMessage',
          'chat_id': chatId,
          'message_id': messageId,
        });
      } on TelegramApiException catch (e) {
        if (e.code == 400 && !reloadedChat) {
          reloadedChat = true;
          _loadedChatIds.remove(chatId);
          await _ensureChatLoaded(chatId);
          return _telegram.sendRequest({
            '@type': 'getMessage',
            'chat_id': chatId,
            'message_id': messageId,
          });
        }
        rethrow;
      }
    });

    final fileId = _extractDocumentFileId(messageResp);
    final localEncryptedPath =
        await _withRetry(() => _downloadFileToPath(fileId));
    final chunkBytes = await File(localEncryptedPath).readAsBytes();

    if (deleteTelegramDiskCache) {
      try {
        await _telegram.sendRequest({
          '@type': 'deleteFile',
          'file_id': fileId,
        });
      } catch (_) {}
    }

    return chunkBytes;
  }

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await action();
      } on TelegramApiException catch (e) {
        if (e.code == 429 && attempt < 4) {
          final match = RegExp(r'(\d+)').firstMatch(e.message);
          final sec = int.tryParse(match?.group(1) ?? '') ?? 5;
          await Future<void>.delayed(Duration(seconds: sec.clamp(1, 60) + 1));
          continue;
        }
        rethrow;
      } on TimeoutException {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  int _extractDocumentFileId(JsonMap messageResp) {
    final content = messageResp['content'];
    if (content is! JsonMap) {
      throw StateError(
        'No valid document content found in the Telegram message.',
      );
    }

    final documentObj = content['document'];
    if (documentObj is! JsonMap) {
      throw StateError('The Telegram message is not a document.');
    }

    final fileObj = documentObj['document'];
    if (fileObj is! JsonMap || fileObj['id'] == null) {
      throw StateError('File ID is missing in the Telegram document.');
    }

    return (fileObj['id'] as num).toInt();
  }

  Future<String> _downloadFileToPath(int fileId) async {
    final resp = await _telegram.sendRequest(
      {
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 16,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      },
      timeout: const Duration(minutes: 5),
    );

    final completedPath = _completedLocalPath(resp);
    if (completedPath != null) {
      return completedPath;
    }

    return _waitForFileDownload(fileId);
  }

  String? _completedLocalPath(JsonMap fileObj) {
    final local = fileObj['local'];
    if (local is JsonMap && local['is_downloading_completed'] == true) {
      final path = local['path'] as String?;
      if (path != null && path.isNotEmpty) {
        return path;
      }
    }
    return null;
  }

  Future<String> _waitForFileDownload(int fileId) {
    final completer = Completer<String>();
    late StreamSubscription<JsonMap> sub;

    sub = _telegram.updates.listen((event) {
      if (event['@type'] == 'updateFile') {
        final fileObj = event['file'];
        if (fileObj is JsonMap && (fileObj['id'] as num?)?.toInt() == fileId) {
          final path = _completedLocalPath(fileObj);
          if (path != null) {
            sub.cancel();
            if (!completer.isCompleted) completer.complete(path);
          }
        }
      }
    });

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        sub.cancel();
        throw TimeoutException(
          'Telegram file download timed out (fileId: $fileId)',
        );
      },
    );
  }

  void _putInRamCache(String mediaId, Uint8List bytes) {
    if (bytes.length > maxRamCacheBytes) return;

    final previous = _ramCache.remove(mediaId);
    if (previous != null) {
      _currentRamCacheBytes -= previous.length;
    }

    while (_currentRamCacheBytes + bytes.length > maxRamCacheBytes &&
        _ramCache.isNotEmpty) {
      final oldestKey = _ramCache.keys.first;
      final removed = _ramCache.remove(oldestKey)!;
      _currentRamCacheBytes -= removed.length;
      removed.fillRange(0, removed.length, 0);
    }

    _ramCache[mediaId] = bytes;
    _currentRamCacheBytes += bytes.length;
  }

  void clearRamCache() {
    for (final bytes in _ramCache.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _ramCache.clear();
    _currentRamCacheBytes = 0;
    _loadedChatIds.clear();
  }
}