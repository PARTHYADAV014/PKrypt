import '../models/vault_channel.dart';
import 'local_db_service.dart';
import 'telegram_service.dart';

class ChannelService {
  final TelegramService _telegram;
  final LocalDbService _db;

  ChannelService({
    required TelegramService telegramService,
    required LocalDbService localDbService,
  })  : _telegram = telegramService,
        _db = localDbService;

  void _ensureTelegramReady() {
    if (!_telegram.isReady) {
      throw StateError('Telegram is not logged in. Please log in first.');
    }
  }

  /// Fresh-install safe: Telegram se channels fetch karta hai bina local Hive DB khole.
  Future<List<VaultChannel>> fetchTelegramChannelsWithoutDb({
    int limit = 100,
  }) async {
    _ensureTelegramReady();

    try {
      await _telegram.sendRequest({
        '@type': 'loadChats',
        'chat_list': {'@type': 'chatListMain'},
        'limit': limit,
      });
    } catch (_) {
      // TDLib returns 404 when all chats are already loaded.
    }

    final chatsResp = await _telegram.sendRequest({
      '@type': 'getChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': limit,
    });

    final rawChatIds = (chatsResp['chat_ids'] as List?) ?? const [];
    final channels = <VaultChannel>[];

    for (final rawId in rawChatIds) {
      try {
        final chatId = (rawId as num).toInt();
        final chat = await _telegram.sendRequest({
          '@type': 'getChat',
          'chat_id': chatId,
        });

        final chatType = chat['type'];
        final isChannel = chatType is Map &&
            chatType['@type'] == 'chatTypeSupergroup' &&
            chatType['is_channel'] == true;

        if (!isChannel) continue;

        final title = (chat['title'] as String?)?.trim();
        channels.add(
          VaultChannel(
            chatId: chatId,
            title:
                (title == null || title.isEmpty) ? 'Untitled Channel' : title,
            addedAt: DateTime.now(),
          ),
        );
      } catch (_) {}
    }

    return channels;
  }

  /// 1. Telegram se saare channels fetch karke local encrypted Hive DB mein sync karo
  Future<List<VaultChannel>> syncChannels({int limit = 100}) async {
    _ensureTelegramReady();

    // Pehle se saved channels ka Primary/Backup status yaad rakho
    final existingById = <int, VaultChannel>{};
    for (final ch in _db.getAllChannels()) {
      existingById[ch.chatId] = ch;
    }

    final fetched = await fetchTelegramChannelsWithoutDb(limit: limit);
    final syncedChannels = <VaultChannel>[];

    for (final ch in fetched) {
      final existing = existingById[ch.chatId];
      final channel = VaultChannel(
        chatId: ch.chatId,
        title: ch.title,
        isPrimary: existing?.isPrimary ?? false,
        isBackup: existing?.isBackup ?? false,
        addedAt: existing?.addedAt ?? DateTime.now(),
      );

      await _db.saveChannel(channel);
      syncedChannels.add(channel);
    }

    return syncedChannels;
  }

  /// 2. App ke andar se hi naya Private Channel banao (Vault ya Backup ke liye)
  Future<VaultChannel> createPrivateChannel({
    required String title,
    String description = 'Pkrypt Encrypted Storage',
    bool setAsPrimary = false,
    bool setAsBackup = false,
  }) async {
    _ensureTelegramReady();
    if (title.trim().isEmpty) {
      throw ArgumentError('Channel name cannot be empty');
    }
    if (setAsPrimary && setAsBackup) {
      throw ArgumentError('Primary and backup channels cannot be the same');
    }

    final chat = await _telegram.sendRequest({
      '@type': 'createNewSupergroupChat',
      'title': title.trim(),
      'is_forum': false,
      'is_channel': true,
      'description': description,
    });

    final chatId = (chat['id'] as num).toInt();
    final channel = VaultChannel(
      chatId: chatId,
      title: (chat['title'] as String?) ?? title.trim(),
      addedAt: DateTime.now(),
    );

    await _db.saveChannel(channel);

    if (setAsPrimary) {
      return setPrimaryChannel(channel);
    }
    if (setAsBackup) {
      return setBackupChannel(channel);
    }
    return channel;
  }

  /// 3. Kisi channel ko Primary Vault Channel set karo
  Future<VaultChannel> setPrimaryChannel(VaultChannel target) async {
    final currentBackup = _db.getBackupChannel();
    if (currentBackup != null && currentBackup.chatId == target.chatId) {
      throw ArgumentError(
        'Primary and backup channels must be different.',
      );
    }

    for (final ch in _db.getAllChannels()) {
      if (ch.isPrimary && ch.chatId != target.chatId) {
        await _db.saveChannel(ch.copyWith(isPrimary: false));
      }
    }

    final updated = target.copyWith(isPrimary: true, isBackup: false);
    await _db.saveChannel(updated);
    return updated;
  }

  /// 4. Kisi channel ko Backup Channel set karo
  Future<VaultChannel> setBackupChannel(VaultChannel target) async {
    final currentPrimary = _db.getPrimaryChannel();
    if (currentPrimary != null && currentPrimary.chatId == target.chatId) {
      throw ArgumentError(
        'Primary and backup channels must be different.',
      );
    }

    for (final ch in _db.getAllChannels()) {
      if (ch.isBackup && ch.chatId != target.chatId) {
        await _db.saveChannel(ch.copyWith(isBackup: false));
      }
    }

    final updated = target.copyWith(isBackup: true, isPrimary: false);
    await _db.saveChannel(updated);
    return updated;
  }

  /// 5. Backup channel hatao (agar user backup band karna chahe)
  Future<void> clearBackupChannel() async {
    final currentBackup = _db.getBackupChannel();
    if (currentBackup != null) {
      await _db.saveChannel(currentBackup.copyWith(isBackup: false));
    }
  }

  List<VaultChannel> getSavedChannels() => _db.getAllChannels();
  VaultChannel? getPrimaryChannel() => _db.getPrimaryChannel();
  VaultChannel? getBackupChannel() => _db.getBackupChannel();
}