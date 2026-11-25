import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../models/face_cluster.dart';
import '../models/vault_channel.dart';
import '../models/vault_media.dart';
import 'crypto_service.dart';
import 'local_db_service.dart';
import 'tdlib_transport.dart';
import 'telegram_service.dart';

class IndexBackupResult {
  final int mediaCount;
  final int channelCount;
  final DateTime timestamp;
  final int messageId;

  const IndexBackupResult({
    required this.mediaCount,
    required this.channelCount,
    required this.timestamp,
    required this.messageId,
  });
}

class IndexBackupService {
  static const int _schemaVersion = 1;
  static const String _captionPrefix = 'VAULT_INDEX_V1';
  static const String _backupFileName = 'vault_index_v1.vaul';
  static const String _keyBundleCaptionPrefix = 'VAULT_KEY_BUNDLE_V1';
  static const String _keyBundleFileName = 'vault_key_bundle_v1.json';

  final CryptoService _crypto;
  final TelegramService _telegram;
  final LocalDbService _db;
  final String _tempDirectoryPath;

  IndexBackupService({
    required CryptoService cryptoService,
    required TelegramService telegramService,
    required LocalDbService localDbService,
    required String tempDirectoryPath,
  })  : _crypto = cryptoService,
        _telegram = telegramService,
        _db = localDbService,
        _tempDirectoryPath = tempDirectoryPath;

  /// Uploads Zero-Knowledge encrypted Key Bundle (VAULT_KEY_BUNDLE_V1) to Primary
  /// and mirrors to Backup Channel for 1 TB theft-proof new-device recovery.
  Future<int> backupKeyBundle(String bundleJson) async {
    _ensureReady();

    final primaryChannel = _db.getPrimaryChannel();
    if (primaryChannel == null) {
      throw StateError(
        'Primary Vault Channel is not set. Please select a channel first.',
      );
    }

    await _ensureChatLoaded(primaryChannel.chatId);

    final now = DateTime.now().toUtc();
    final indexDir = await _resolveIndexDirectory();
    if (!await indexDir.exists()) {
      await indexDir.create(recursive: true);
    }

    final tempFile = File(
      '${indexDir.path}${Platform.pathSeparator}$_keyBundleFileName',
    );

    try {
      await tempFile.writeAsBytes(utf8.encode(bundleJson), flush: true);

      final caption = '$_keyBundleCaptionPrefix|${now.toIso8601String()}';
      final messageId = await _sendDocumentMessage(
        chatId: primaryChannel.chatId,
        filePath: tempFile.absolute.path,
        caption: caption,
      );

      final backupChannel = _db.getBackupChannel();
      if (backupChannel != null) {
        try {
          await _ensureChatLoaded(backupChannel.chatId);
          await _forwardMessage(
            fromChatId: primaryChannel.chatId,
            toChatId: backupChannel.chatId,
            messageId: messageId,
          );
        } catch (_) {}
      }

      return messageId;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  /// Downloads the latest VAULT_KEY_BUNDLE_V1 JSON from Telegram (works on a fresh device).
  Future<String> downloadLatestKeyBundle({int? chatId}) async {
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in. Please log in first.');
    }

    final targetChatId = chatId ??
        (_db.isOpen
            ? (_db.getPrimaryChannel()?.chatId ??
                _db.getBackupChannel()?.chatId)
            : null);

    if (targetChatId == null) {
      throw StateError('No vault channel specified for key bundle recovery.');
    }

    await _ensureChatLoaded(targetChatId);

    final bundleMessage = await _findLatestMessageByPrefix(
      chatId: targetChatId,
      prefix: _keyBundleCaptionPrefix,
      fileNameFallback: _keyBundleFileName,
      checkPinnedFirst: false,
    );

    if (bundleMessage == null) {
      throw StateError(
        'No VAULT_KEY_BUNDLE_V1 backup found in the selected channel.',
      );
    }

    final fileId = _extractDocumentFileId(bundleMessage);
    final localPath = await _downloadFileToPath(fileId);

    try {
      return await File(localPath).readAsString();
    } finally {
      try {
        await _telegram.sendRequest({
          '@type': 'deleteFile',
          'file_id': fileId,
        });
      } catch (_) {}
    }
  }

  /// Encrypts the full Hive index (media + channels + face clusters),
  /// uploads to Primary Channel, pins it, and mirrors to Backup Channel.
  Future<IndexBackupResult> backupIndex() async {
    _ensureReady();

    final primaryChannel = _db.getPrimaryChannel();
    if (primaryChannel == null) {
      throw StateError(
        'Primary Vault Channel is not set. Please select a channel first.',
      );
    }

    await _ensureChatLoaded(primaryChannel.chatId);

    final mediaList = _db.getAllMedia();
    final channelList = _db.getAllChannels();
    final faceClusters = _db.getAllFaceClusters();
    final now = DateTime.now().toUtc();

    final snapshot = <String, dynamic>{
      'schemaVersion': _schemaVersion,
      'exportedAt': now.toIso8601String(),
      'channels': channelList.map(_channelToJson).toList(),
      'media': mediaList.map(_mediaToJson).toList(),
      'faceClusters': faceClusters.map(_faceClusterToJson).toList(),
    };

    final jsonBytes = utf8.encode(jsonEncode(snapshot));
    final compressedBytes = Uint8List.fromList(gzip.encode(jsonBytes));
    final encryptedBytes = await _crypto.encrypt(compressedBytes);

    final indexDir = await _resolveIndexDirectory();
    if (!await indexDir.exists()) {
      await indexDir.create(recursive: true);
    }

    final tempFile = File(
      '${indexDir.path}${Platform.pathSeparator}$_backupFileName',
    );

    try {
      await tempFile.writeAsBytes(encryptedBytes, flush: true);

      final caption =
          '$_captionPrefix|${now.toIso8601String()}|${mediaList.length}';

      final messageId = await _sendDocumentMessage(
        chatId: primaryChannel.chatId,
        filePath: tempFile.absolute.path,
        caption: caption,
      );

      await _tryPinMessage(
        chatId: primaryChannel.chatId,
        messageId: messageId,
      );

      final backupChannel = _db.getBackupChannel();
      if (backupChannel != null) {
        try {
          await _ensureChatLoaded(backupChannel.chatId);
          final forwardedId = await _forwardMessage(
            fromChatId: primaryChannel.chatId,
            toChatId: backupChannel.chatId,
            messageId: messageId,
          );
          if (forwardedId != null) {
            await _tryPinMessage(
              chatId: backupChannel.chatId,
              messageId: forwardedId,
            );
          }
        } catch (_) {}
      }

      return IndexBackupResult(
        mediaCount: mediaList.length,
        channelCount: channelList.length,
        timestamp: now.toLocal(),
        messageId: messageId,
      );
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  /// Downloads the latest encrypted index snapshot from Telegram
  /// and restores all channels, media metadata, and People clusters.
  Future<IndexBackupResult> restoreLatestIndex({int? chatId}) async {
    _ensureReady();

    final targetChatId = chatId ??
        _db.getPrimaryChannel()?.chatId ??
        _db.getBackupChannel()?.chatId;

    if (targetChatId == null) {
      throw StateError(
        'No vault channel selected. Select your Primary Channel before restoring.',
      );
    }

    await _ensureChatLoaded(targetChatId);

    JsonMap? indexMessage = await _findLatestMessageByPrefix(
      chatId: targetChatId,
      prefix: _captionPrefix,
      fileNameFallback: _backupFileName,
      checkPinnedFirst: true,
    );

    if (indexMessage == null) {
      final backupChatId = _db.getBackupChannel()?.chatId;
      if (backupChatId != null && backupChatId != targetChatId) {
        await _ensureChatLoaded(backupChatId);
        indexMessage = await _findLatestMessageByPrefix(
          chatId: backupChatId,
          prefix: _captionPrefix,
          fileNameFallback: _backupFileName,
          checkPinnedFirst: true,
        );
      }
    }

    if (indexMessage == null) {
      throw StateError(
        'No encrypted cloud index backup found in the selected channel. Tap "Backup Cloud Index Now" first.',
      );
    }

    final messageId = (indexMessage['id'] as num).toInt();
    final fileId = _extractDocumentFileId(indexMessage);
    final localPath = await _downloadFileToPath(fileId);

    Uint8List encryptedBytes;
    try {
      encryptedBytes = await File(localPath).readAsBytes();
    } finally {
      try {
        await _telegram.sendRequest({
          '@type': 'deleteFile',
          'file_id': fileId,
        });
      } catch (_) {}
    }

    final compressedBytes = await _crypto.decrypt(encryptedBytes);
    final jsonString = utf8.decode(gzip.decode(compressedBytes));
    final decoded = jsonDecode(jsonString);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid cloud index format.');
    }

    final rawChannels = (decoded['channels'] as List?) ?? const [];
    final rawMedia = (decoded['media'] as List?) ?? const [];
    final rawFaces = (decoded['faceClusters'] as List?) ?? const [];

    int restoredChannels = 0;
    for (final entry in rawChannels) {
      if (entry is Map) {
        final channel = _channelFromJson(Map<String, dynamic>.from(entry));
        await _db.saveChannel(channel);
        restoredChannels++;
      }
    }

    int restoredMedia = 0;
    for (final entry in rawMedia) {
      if (entry is Map) {
        final media = _mediaFromJson(Map<String, dynamic>.from(entry));
        await _db.saveMedia(media);
        restoredMedia++;
      }
    }

    for (final entry in rawFaces) {
      if (entry is Map) {
        final cluster = _faceClusterFromJson(Map<String, dynamic>.from(entry));
        await _db.saveFaceCluster(cluster);
      }
    }

    final exportedAtRaw = decoded['exportedAt'] as String?;
    final timestamp = (exportedAtRaw != null
            ? DateTime.tryParse(exportedAtRaw)?.toLocal()
            : null) ??
        DateTime.now();

    return IndexBackupResult(
      mediaCount: restoredMedia,
      channelCount: restoredChannels,
      timestamp: timestamp,
      messageId: messageId,
    );
  }

  Future<Directory> _resolveIndexDirectory() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      return Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_index',
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

  void _ensureReady() {
    if (!_crypto.isUnlocked || !_db.isOpen) {
      throw StateError('Vault is locked. Please unlock the vault first.');
    }
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in. Please log in first.');
    }
  }

  Future<JsonMap?> _findLatestMessageByPrefix({
    required int chatId,
    required String prefix,
    required String fileNameFallback,
    required bool checkPinnedFirst,
  }) async {
    if (checkPinnedFirst) {
      final pinned = await _searchMessagesByPrefix(
        chatId: chatId,
        filterType: 'searchMessagesFilterPinned',
        query: '',
        prefix: prefix,
        fileNameFallback: fileNameFallback,
        limit: 20,
      );
      if (pinned != null) return pinned;
    }

    final fromHistory = await _scanRecentHistoryForBackup(
      chatId: chatId,
      prefix: prefix,
      fileNameFallback: fileNameFallback,
    );
    if (fromHistory != null) return fromHistory;

    final docSearch = await _searchMessagesByPrefix(
      chatId: chatId,
      filterType: 'searchMessagesFilterDocument',
      query: prefix,
      prefix: prefix,
      fileNameFallback: fileNameFallback,
      limit: 20,
    );
    if (docSearch != null) return docSearch;

    final allDocs = await _searchMessagesByPrefix(
      chatId: chatId,
      filterType: 'searchMessagesFilterDocument',
      query: '',
      prefix: prefix,
      fileNameFallback: fileNameFallback,
      limit: 50,
    );
    if (allDocs != null) return allDocs;

    return _searchMessagesByPrefix(
      chatId: chatId,
      filterType: 'searchMessagesFilterEmpty',
      query: prefix,
      prefix: prefix,
      fileNameFallback: fileNameFallback,
      limit: 20,
    );
  }

  Future<JsonMap?> _scanRecentHistoryForBackup({
    required int chatId,
    required String prefix,
    required String fileNameFallback,
  }) async {
    int fromMessageId = 0;

    for (int page = 0; page < 4; page++) {
      try {
        final resp = await _telegram.sendRequest({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': fromMessageId,
          'offset': 0,
          'limit': 50,
          'only_local': false,
        });

        final messages = (resp['messages'] as List?) ?? const [];
        if (messages.isEmpty) break;

        int? oldestIdInBatch;
        for (final raw in messages) {
          if (raw is JsonMap) {
            final msgId = (raw['id'] as num?)?.toInt();
            if (msgId != null) oldestIdInBatch = msgId;
            if (_matchesBackupDocument(raw, prefix, fileNameFallback)) {
              return raw;
            }
          }
        }

        if (oldestIdInBatch == null || oldestIdInBatch == fromMessageId) {
          break;
        }
        fromMessageId = oldestIdInBatch;
      } catch (_) {
        break;
      }
    }

    return null;
  }

  Future<JsonMap?> _searchMessagesByPrefix({
    required int chatId,
    required String filterType,
    required String query,
    required String prefix,
    required String fileNameFallback,
    int limit = 20,
  }) async {
    try {
      final resp = await _telegram.sendRequest({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': query,
        'from_message_id': 0,
        'offset': 0,
        'limit': limit,
        'filter': {'@type': filterType},
        'message_thread_id': 0,
      });

      final messages = (resp['messages'] as List?) ?? const [];
      for (final raw in messages) {
        if (raw is JsonMap &&
            _matchesBackupDocument(raw, prefix, fileNameFallback)) {
          return raw;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _matchesBackupDocument(
    JsonMap message,
    String prefix,
    String fileNameFallback,
  ) {
    final content = message['content'];
    if (content is! JsonMap || content['@type'] != 'messageDocument') {
      return false;
    }

    final captionObj = content['caption'];
    final captionText = captionObj is JsonMap
        ? (captionObj['text'] as String?) ?? ''
        : '';
    if (captionText.startsWith(prefix)) {
      return true;
    }

    final docObj = content['document'];
    final docFileName = docObj is JsonMap
        ? (docObj['file_name'] as String?) ?? ''
        : '';
    return docFileName == fileNameFallback;
  }

  Future<int> _sendDocumentMessage({
    required int chatId,
    required String filePath,
    required String caption,
  }) async {
    final localInputFile = <String, dynamic>{
      '@type': 'inputFileLocal',
      'path': filePath,
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
            (error?['message'] as String?) ?? 'Cloud upload failed';
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
          (err?['message'] as String?) ?? 'Cloud send failed immediately',
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
        const Duration(minutes: 3),
        onTimeout: () => throw TimeoutException('Cloud upload timed out.'),
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _tryPinMessage({
    required int chatId,
    required int messageId,
  }) async {
    try {
      await _telegram.sendRequest({
        '@type': 'pinChatMessage',
        'chat_id': chatId,
        'message_id': messageId,
        'disable_notification': true,
        'only_for_self': false,
      });
    } catch (_) {}
  }

  Future<int?> _forwardMessage({
    required int fromChatId,
    required int toChatId,
    required int messageId,
  }) async {
    final resp = await _telegram.sendRequest({
      '@type': 'forwardMessages',
      'chat_id': toChatId,
      'from_chat_id': fromChatId,
      'message_ids': [messageId],
      'send_copy': false,
      'remove_caption': false,
    });
    final messages = (resp['messages'] as List?) ?? const [];
    if (messages.isNotEmpty && messages.first is JsonMap) {
      final id = (messages.first as JsonMap)['id'];
      if (id is num) return id.toInt();
    }
    return null;
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
        'priority': 20,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      },
      timeout: const Duration(minutes: 3),
    );

    final completedPath = _completedLocalPath(resp);
    if (completedPath != null) return completedPath;

    return _waitForFileDownload(fileId);
  }

  String? _completedLocalPath(JsonMap fileObj) {
    final local = fileObj['local'];
    if (local is JsonMap && local['is_downloading_completed'] == true) {
      final path = local['path'] as String?;
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  Future<String> _waitForFileDownload(int fileId) {
    final completer = Completer<String>();
    late StreamSubscription<JsonMap> sub;

    sub = _telegram.updates.listen((event) {
      if (event['@type'] == 'updateFile') {
        final fileObj = event['file'];
        if (fileObj is JsonMap &&
            (fileObj['id'] as num?)?.toInt() == fileId) {
          final path = _completedLocalPath(fileObj);
          if (path != null) {
            sub.cancel();
            if (!completer.isCompleted) completer.complete(path);
          }
        }
      }
    });

    return completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        sub.cancel();
        throw TimeoutException('Cloud download timed out.');
      },
    );
  }

  Map<String, dynamic> _channelToJson(VaultChannel ch) => {
        'chatId': ch.chatId,
        'title': ch.title,
        'isPrimary': ch.isPrimary,
        'isBackup': ch.isBackup,
        'addedAt': ch.addedAt.toUtc().toIso8601String(),
      };

  VaultChannel _channelFromJson(Map<String, dynamic> map) => VaultChannel(
        chatId: (map['chatId'] as num).toInt(),
        title: (map['title'] as String?) ?? 'Untitled Channel',
        isPrimary: (map['isPrimary'] as bool?) ?? false,
        isBackup: (map['isBackup'] as bool?) ?? false,
        addedAt: DateTime.tryParse((map['addedAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.now(),
      );

  Map<String, dynamic> _mediaToJson(VaultMedia m) => {
        'id': m.id,
        'fileName': m.fileName,
        'mimeType': m.mimeType,
        'sizeBytes': m.sizeBytes,
        'createdAt': m.createdAt.toUtc().toIso8601String(),
        'album': m.album,
        'isFavorite': m.isFavorite,
        'uploadStatus': m.uploadStatus,
        'primaryChatId': m.primaryChatId,
        'chunkMessageIds': m.chunkMessageIds,
        'backupChatId': m.backupChatId,
        'backupMessageIds': m.backupMessageIds,
        'faceClusterIds': m.faceClusterIds,
        'contentHash': m.contentHash,
        'isPerChunkEncrypted': m.isPerChunkEncrypted,
        'facesScanned': m.facesScanned,
      };

  VaultMedia _mediaFromJson(Map<String, dynamic> map) => VaultMedia(
        id: map['id'] as String,
        fileName: (map['fileName'] as String?) ?? 'file',
        mimeType: (map['mimeType'] as String?) ?? 'application/octet-stream',
        sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse((map['createdAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.now(),
        album: (map['album'] as String?) ?? 'All',
        isFavorite: (map['isFavorite'] as bool?) ?? false,
        uploadStatus: (map['uploadStatus'] as String?) ?? 'uploaded',
        primaryChatId: (map['primaryChatId'] as num?)?.toInt(),
        chunkMessageIds: ((map['chunkMessageIds'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        backupChatId: (map['backupChatId'] as num?)?.toInt(),
        backupMessageIds: ((map['backupMessageIds'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        faceClusterIds: ((map['faceClusterIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        contentHash: map['contentHash'] as String?,
        isPerChunkEncrypted: (map['isPerChunkEncrypted'] as bool?) ?? false,
        facesScanned: (map['facesScanned'] as bool?) ?? false,
      );

  Map<String, dynamic> _faceClusterToJson(FaceCluster fc) => {
        'id': fc.id,
        'name': fc.name,
        'embedding': fc.embedding,
        'sampleCount': fc.sampleCount,
        'createdAt': fc.createdAt.toUtc().toIso8601String(),
      };

  FaceCluster _faceClusterFromJson(Map<String, dynamic> map) => FaceCluster(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? 'Person',
        embedding: ((map['embedding'] as List?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(),
        sampleCount: (map['sampleCount'] as num?)?.toInt() ?? 1,
        createdAt: DateTime.tryParse((map['createdAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.now(),
      );
}