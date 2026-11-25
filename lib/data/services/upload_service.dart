import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import '../models/vault_media.dart';
import 'crypto_service.dart';
import 'local_db_service.dart';
import 'tdlib_transport.dart';
import 'telegram_service.dart';

class DuplicateMediaException implements Exception {
  final VaultMedia existingMedia;
  const DuplicateMediaException(this.existingMedia);

  @override
  String toString() =>
      'Duplicate skipped: "${existingMedia.fileName}" is already in your vault.';
}

class LockedUploadResult {
  final String mediaId;
  final String contentHash;
  final int sizeBytes;
  final List<int> chunkMessageIds;
  final int? backupChatId;
  final List<int> backupMessageIds;
  final bool isPerChunkEncrypted;

  const LockedUploadResult({
    required this.mediaId,
    required this.contentHash,
    required this.sizeBytes,
    required this.chunkMessageIds,
    this.backupChatId,
    this.backupMessageIds = const [],
    required this.isPerChunkEncrypted,
  });
}

class UploadService {
  static const int defaultChunkSizeBytes = 10 * 1024 * 1024; // 10 MB per chunk

  final CryptoService _crypto;
  final TelegramService _telegram;
  final LocalDbService _db;
  final String _tempDirectoryPath;
  final int chunkSizeBytes;

  UploadService({
    required CryptoService cryptoService,
    required TelegramService telegramService,
    required LocalDbService localDbService,
    required String tempDirectoryPath,
    this.chunkSizeBytes = defaultChunkSizeBytes,
  })  : _crypto = cryptoService,
        _telegram = telegramService,
        _db = localDbService,
        _tempDirectoryPath = tempDirectoryPath;

  /// Streaming SHA-256 hash of a file on disk (zero RAM spike for large videos).
  Future<String> computeFileSha256(String filePath) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in File(filePath).openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final hash = await sink.hash();
    return _bytesToHex(hash.bytes);
  }

  Future<String> computeBytesSha256(Uint8List bytes) async {
    final hash = await Sha256().hash(bytes);
    return _bytesToHex(hash.bytes);
  }

  /// Cleans any leftover encrypted chunk or temp playback files on disk.
  Future<void> cleanupStaleTempFiles() async {
    try {
      final chunkDir = await _resolveChunkDirectory();
      if (await chunkDir.exists()) {
        await for (final entity in chunkDir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    try {
      final tempDir = await getTemporaryDirectory();
      await for (final entity in tempDir.list()) {
        if (entity is File && entity.path.contains('vault_play_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Streams a file from disk in 10 MB chunks -> encrypts each chunk -> uploads to Telegram.
  /// Safe for 500 MB - 2 GB videos (peak RAM stays ~15-20 MB).
  Future<VaultMedia> uploadFileStream({
    required String filePath,
    required String fileName,
    required String mimeType,
    String album = 'All',
    String? customId,
    bool skipIfDuplicate = true,
    void Function(double progress)? onProgress,
  }) async {
    if (!_crypto.isUnlocked) {
      throw StateError('Vault is locked. Unlock the vault before uploading.');
    }
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in.');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('File not found: $filePath');
    }
    final totalBytes = await file.length();
    if (totalBytes <= 0) {
      throw StateError(
        'Selected file is empty (0 bytes) and cannot be uploaded.',
      );
    }

    final primaryChannel = _db.getPrimaryChannel();
    if (primaryChannel == null) {
      throw StateError(
        'Primary Vault Channel is not set. Please select a channel first.',
      );
    }

    onProgress?.call(0.03);
    final contentHash = await computeFileSha256(filePath);
    if (skipIfDuplicate) {
      final existing = _db.findMediaByHash(contentHash);
      if (existing != null) {
        throw DuplicateMediaException(existing);
      }
    }

    await _ensureChatLoaded(primaryChannel.chatId);

    final mediaId = customId ?? _generateMediaId();
    final totalChunks = (totalBytes + chunkSizeBytes - 1) ~/ chunkSizeBytes;
    final uploadedMessageIds = <int>[];

    final chunkDir = await _resolveChunkDirectory();
    if (!await chunkDir.exists()) {
      await chunkDir.create(recursive: true);
    }

    onProgress?.call(0.08);

    final raf = await file.open(mode: FileMode.read);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final remaining = totalBytes - (i * chunkSizeBytes);
        final toRead =
            remaining < chunkSizeBytes ? remaining : chunkSizeBytes;
        final plainChunk = await raf.read(toRead);
        final encryptedChunk = await _crypto.encrypt(plainChunk);

        final chunkFile = File(
          '${chunkDir.path}${Platform.pathSeparator}${mediaId}_part_$i.vaul',
        );

        try {
          await chunkFile.writeAsBytes(encryptedChunk, flush: true);
          final finalMessageId = await _withFloodWaitRetry(
            () => _sendChunkToChannel(
              chatId: primaryChannel.chatId,
              chunkFilePath: chunkFile.absolute.path,
              caption: 'VAULT:$mediaId:${i + 1}/$totalChunks',
            ),
          );
          uploadedMessageIds.add(finalMessageId);
          onProgress?.call(0.08 + (((i + 1) / totalChunks) * 0.80));
        } finally {
          if (await chunkFile.exists()) {
            await chunkFile.delete();
          }
        }
      }
    } finally {
      await raf.close();
    }

    // Server-side mirror to Backup Channel (optional)
    final backupChannel = _db.getBackupChannel();
    int? backupChatId;
    var backupMessageIds = <int>[];

    if (backupChannel != null && uploadedMessageIds.isNotEmpty) {
      try {
        await _ensureChatLoaded(backupChannel.chatId);
        backupChatId = backupChannel.chatId;
        backupMessageIds = await _withFloodWaitRetry(
          () => _forwardChunksToBackup(
            fromChatId: primaryChannel.chatId,
            toBackupChatId: backupChannel.chatId,
            messageIds: uploadedMessageIds,
          ),
        );
      } catch (_) {
        backupChatId = null;
        backupMessageIds = const [];
      }
    }

    onProgress?.call(0.95);

    final media = VaultMedia(
      id: mediaId,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: totalBytes,
      createdAt: DateTime.now(),
      album: album,
      uploadStatus: 'uploaded',
      primaryChatId: primaryChannel.chatId,
      chunkMessageIds: uploadedMessageIds,
      backupChatId: backupChatId,
      backupMessageIds: backupMessageIds,
      contentHash: contentHash,
      isPerChunkEncrypted: totalChunks > 1,
    );
    await _db.saveMedia(media);
    onProgress?.call(1.0);
    return media;
  }

  /// Zero-Knowledge Locked Upload: encrypts file chunks with X25519 Public Key (VGZ1)
  /// without needing Master Password or Hive DB open. Used by Phase 2B background service.
  Future<LockedUploadResult> uploadFileLockedWithPublicKey({
    required String filePath,
    required int primaryChatId,
    int? backupChatId,
    required Uint8List x25519PublicKeyBytes,
    String? customId,
    void Function(double progress)? onProgress,
  }) async {
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in.');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('File not found: $filePath');
    }
    final totalBytes = await file.length();
    if (totalBytes <= 0) {
      throw StateError('File is empty (0 bytes).');
    }

    final contentHash = await computeFileSha256(filePath);
    await _ensureChatLoaded(primaryChatId);

    final mediaId = customId ?? _generateMediaId();
    final totalChunks = (totalBytes + chunkSizeBytes - 1) ~/ chunkSizeBytes;
    final uploadedMessageIds = <int>[];

    final chunkDir = await _resolveChunkDirectory();
    if (!await chunkDir.exists()) {
      await chunkDir.create(recursive: true);
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final remaining = totalBytes - (i * chunkSizeBytes);
        final toRead =
            remaining < chunkSizeBytes ? remaining : chunkSizeBytes;
        final plainChunk = await raf.read(toRead);
        final encryptedChunk = await _crypto.encryptForPublicKey(
          plaintext: plainChunk,
          recipientPublicKeyBytes: x25519PublicKeyBytes,
        );

        final chunkFile = File(
          '${chunkDir.path}${Platform.pathSeparator}${mediaId}_zk_$i.vaul',
        );

        try {
          await chunkFile.writeAsBytes(encryptedChunk, flush: true);
          final finalMessageId = await _withFloodWaitRetry(
            () => _sendChunkToChannel(
              chatId: primaryChatId,
              chunkFilePath: chunkFile.absolute.path,
              caption: 'VAULT_ZK:$mediaId:${i + 1}/$totalChunks',
            ),
          );
          uploadedMessageIds.add(finalMessageId);
          onProgress?.call(((i + 1) / totalChunks) * 0.90);
        } finally {
          if (await chunkFile.exists()) {
            await chunkFile.delete();
          }
        }
      }
    } finally {
      await raf.close();
    }

    var backupMessageIds = <int>[];
    int? confirmedBackupChatId;
    if (backupChatId != null && uploadedMessageIds.isNotEmpty) {
      try {
        await _ensureChatLoaded(backupChatId);
        backupMessageIds = await _withFloodWaitRetry(
          () => _forwardChunksToBackup(
            fromChatId: primaryChatId,
            toBackupChatId: backupChatId,
            messageIds: uploadedMessageIds,
          ),
        );
        confirmedBackupChatId = backupChatId;
      } catch (_) {}
    }

    onProgress?.call(1.0);
    return LockedUploadResult(
      mediaId: mediaId,
      contentHash: contentHash,
      sizeBytes: totalBytes,
      chunkMessageIds: uploadedMessageIds,
      backupChatId: confirmedBackupChatId,
      backupMessageIds: backupMessageIds,
      isPerChunkEncrypted: totalChunks > 1,
    );
  }

  /// In-memory byte upload (kept for compatibility & small photos).
  Future<VaultMedia> uploadMedia({
    required Uint8List plainBytes,
    required String fileName,
    required String mimeType,
    String album = 'All',
    String? customId,
    bool skipIfDuplicate = true,
    void Function(double progress)? onProgress,
  }) async {
    if (!_crypto.isUnlocked) {
      throw StateError('Vault is locked. Unlock the vault before uploading.');
    }
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in.');
    }
    if (plainBytes.isEmpty) {
      throw StateError(
        'Selected file is empty (0 bytes) and cannot be uploaded.',
      );
    }

    final primaryChannel = _db.getPrimaryChannel();
    if (primaryChannel == null) {
      throw StateError(
        'Primary Vault Channel is not set. Please select a channel first.',
      );
    }

    final contentHash = await computeBytesSha256(plainBytes);
    if (skipIfDuplicate) {
      final existing = _db.findMediaByHash(contentHash);
      if (existing != null) {
        throw DuplicateMediaException(existing);
      }
    }

    await _ensureChatLoaded(primaryChannel.chatId);

    final mediaId = customId ?? _generateMediaId();
    onProgress?.call(0.05);

    final plainChunks = _splitIntoChunks(plainBytes, chunkSizeBytes);
    final uploadedMessageIds = <int>[];

    final chunkDir = await _resolveChunkDirectory();
    if (!await chunkDir.exists()) {
      await chunkDir.create(recursive: true);
    }

    for (int i = 0; i < plainChunks.length; i++) {
      final encryptedChunk = await _crypto.encrypt(plainChunks[i]);
      final chunkFile = File(
        '${chunkDir.path}${Platform.pathSeparator}${mediaId}_part_$i.vaul',
      );

      try {
        await chunkFile.writeAsBytes(encryptedChunk, flush: true);
        final finalMessageId = await _withFloodWaitRetry(
          () => _sendChunkToChannel(
            chatId: primaryChannel.chatId,
            chunkFilePath: chunkFile.absolute.path,
            caption: 'VAULT:$mediaId:${i + 1}/${plainChunks.length}',
          ),
        );
        uploadedMessageIds.add(finalMessageId);

        final uploadFraction = (i + 1) / plainChunks.length;
        onProgress?.call(0.15 + (uploadFraction * 0.70));
      } finally {
        if (await chunkFile.exists()) {
          await chunkFile.delete();
        }
      }
    }

    final backupChannel = _db.getBackupChannel();
    int? backupChatId;
    var backupMessageIds = <int>[];

    if (backupChannel != null && uploadedMessageIds.isNotEmpty) {
      try {
        await _ensureChatLoaded(backupChannel.chatId);
        backupChatId = backupChannel.chatId;
        backupMessageIds = await _withFloodWaitRetry(
          () => _forwardChunksToBackup(
            fromChatId: primaryChannel.chatId,
            toBackupChatId: backupChannel.chatId,
            messageIds: uploadedMessageIds,
          ),
        );
      } catch (_) {
        backupChatId = null;
        backupMessageIds = const [];
      }
    }

    onProgress?.call(0.95);

    final media = VaultMedia(
      id: mediaId,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: plainBytes.length,
      createdAt: DateTime.now(),
      album: album,
      uploadStatus: 'uploaded',
      primaryChatId: primaryChannel.chatId,
      chunkMessageIds: uploadedMessageIds,
      backupChatId: backupChatId,
      backupMessageIds: backupMessageIds,
      contentHash: contentHash,
      isPerChunkEncrypted: plainChunks.length > 1,
    );
    await _db.saveMedia(media);
    onProgress?.call(1.0);

    return media;
  }

  /// Auto-retries Telegram 429 FLOOD_WAIT and transient network timeouts.
  Future<T> _withFloodWaitRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 4,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await action();
      } on TelegramApiException catch (e) {
        final floodSeconds = _parseFloodWaitSeconds(e);
        if (floodSeconds != null && attempt < maxAttempts) {
          final clamped = floodSeconds.clamp(1, 120);
          await Future<void>.delayed(Duration(seconds: clamped + 1));
          continue;
        }
        rethrow;
      } on TimeoutException {
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      } on SocketException {
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  int? _parseFloodWaitSeconds(TelegramApiException e) {
    final msg = e.message;
    final match = RegExp(
      r'(?:retry after |FLOOD_WAIT_)(\d+)',
      caseSensitive: false,
    ).firstMatch(msg);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    if (e.code == 429) return 5;
    return null;
  }

  String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Future<Directory> _resolveChunkDirectory() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      return Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_chunks',
      );
    } catch (_) {
      return Directory(_tempDirectoryPath);
    }
  }

  Future<void> _ensureChatLoaded(int chatId) async {
    try {
      await _telegram.sendRequest({
        '@type': 'getChat',
        'chat_id': chatId,
      });
    } catch (_) {
      try {
        await _telegram.sendRequest({
          '@type': 'getChats',
          'chat_list': {'@type': 'chatListMain'},
          'limit': 100,
        });
      } catch (_) {}
      await _telegram.sendRequest({
        '@type': 'getChat',
        'chat_id': chatId,
      });
    }
  }

  List<Uint8List> _splitIntoChunks(Uint8List data, int maxChunkSize) {
    final result = <Uint8List>[];
    for (int offset = 0; offset < data.length; offset += maxChunkSize) {
      final end = (offset + maxChunkSize > data.length)
          ? data.length
          : offset + maxChunkSize;
      result.add(Uint8List.sublistView(data, offset, end));
    }
    return result;
  }

  Future<int> _sendChunkToChannel({
    required int chatId,
    required String chunkFilePath,
    required String caption,
  }) async {
    final localInputFile = <String, dynamic>{
      '@type': 'inputFileLocal',
      'path': chunkFilePath,
    };

    try {
      return await _sendDocumentRequest(
        chatId: chatId,
        documentPayload: {
          '@type': 'inputDocument',
          'document': localInputFile,
          'disable_content_type_detection': true,
        },
        caption: caption,
      );
    } catch (e) {
      if (e.toString().contains('InputFile is not specified') ||
          e.toString().contains('inputDocument')) {
        return _sendDocumentRequest(
          chatId: chatId,
          documentPayload: localInputFile,
          caption: caption,
        );
      }
      rethrow;
    }
  }

  Future<int> _sendDocumentRequest({
    required int chatId,
    required JsonMap documentPayload,
    required String caption,
  }) async {
    final earlyEvents = <JsonMap>[];
    final completer = Completer<int>();
    int? pendingTempId;
    late StreamSubscription<JsonMap> sub;

    void processEvent(JsonMap event) {
      if (pendingTempId == null || completer.isCompleted) return;
      final type = event['@type'];
      final oldId = (event['old_message_id'] as num?)?.toInt();
      if (oldId != pendingTempId) return;

      if (type == 'updateMessageSendSucceeded') {
        final msg = event['message'] as JsonMap;
        final serverId = (msg['id'] as num).toInt();
        completer.complete(serverId);
      } else if (type == 'updateMessageSendFailed') {
        final error = event['error'] as JsonMap?;
        final code = (error?['code'] as int?) ?? -1;
        final message =
            (error?['message'] as String?) ?? 'Chunk upload failed';
        completer.completeError(TelegramApiException(code, message));
      }
    }

    sub = _telegram.updates.listen((event) {
      final type = event['@type'];
      if (type == 'updateMessageSendSucceeded' ||
          type == 'updateMessageSendFailed') {
        if (pendingTempId == null) {
          earlyEvents.add(event);
        } else {
          processEvent(event);
        }
      }
    });

    try {
      final resp = await _telegram.sendRequest({
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageDocument',
          'document': documentPayload,
          'disable_content_type_detection': true,
          'caption': {
            '@type': 'formattedText',
            'text': caption,
          },
        },
      });

      final msgId = (resp['id'] as num).toInt();
      final sendingState = resp['sending_state'];

      if (sendingState is JsonMap &&
          sendingState['@type'] == 'messageSendingStateFailed') {
        final err = sendingState['error'] as JsonMap?;
        throw TelegramApiException(
          (err?['code'] as int?) ?? -1,
          (err?['message'] as String?) ?? 'Message send failed immediately',
        );
      }

      if (sendingState is! JsonMap ||
          sendingState['@type'] != 'messageSendingStatePending') {
        return msgId;
      }

      pendingTempId = msgId;
      for (final e in earlyEvents) {
        processEvent(e);
      }

      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () =>
            throw TimeoutException('Telegram chunk upload timed out.'),
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<List<int>> _forwardChunksToBackup({
    required int fromChatId,
    required int toBackupChatId,
    required List<int> messageIds,
  }) async {
    final resp = await _telegram.sendRequest({
      '@type': 'forwardMessages',
      'chat_id': toBackupChatId,
      'from_chat_id': fromChatId,
      'message_ids': messageIds,
      'send_copy': false,
      'remove_caption': false,
    });

    final rawMessages = (resp['messages'] as List?) ?? const [];
    final forwardedIds = <int>[];

    for (final item in rawMessages) {
      if (item is JsonMap && item['id'] != null) {
        forwardedIds.add((item['id'] as num).toInt());
      }
    }

    return forwardedIds;
  }

  String _generateMediaId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'media_$now';
  }
}