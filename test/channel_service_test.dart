import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/channel_service.dart';
import 'package:vault_gallery/data/services/local_db_service.dart';
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

class _FakeChannelTransport implements TdlibTransport {
  final _controller = StreamController<JsonMap>.broadcast();
  final Map<int, JsonMap> chats = {
    -1001111111: {
      '@type': 'chat',
      'id': -1001111111,
      'title': 'Vault Main',
      'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
    },
    -1002222222: {
      '@type': 'chat',
      'id': -1002222222,
      'title': 'Vault Backup',
      'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
    },
    55555: {
      '@type': 'chat',
      'id': 55555,
      'title': 'Friend DM',
      'type': {'@type': 'chatTypePrivate'},
    },
    -99999: {
      '@type': 'chat',
      'id': -99999,
      'title': 'College Group',
      'type': {'@type': 'chatTypeSupergroup', 'is_channel': false},
    },
  };

  int _nextChannelId = -1003333333;

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
    } else if (type == 'getChats') {
      _emit({
        '@type': 'chats',
        'chat_ids': chats.keys.toList(),
        '@extra': extra,
      });
    } else if (type == 'getChat') {
      final id = (request['chat_id'] as num).toInt();
      final chat = chats[id]!;
      _emit({...chat, '@extra': extra});
    } else if (type == 'createNewSupergroupChat') {
      final newId = _nextChannelId--;
      final newChat = <String, dynamic>{
        '@type': 'chat',
        'id': newId,
        'title': request['title'],
        'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
      };
      chats[newId] = newChat;
      _emit({...newChat, '@extra': extra});
    }
  }

  @override
  Future<void> stop() async {
    await _controller.close();
  }
}

void main() {
  late Directory tempDir;
  late LocalDbService db;
  late TelegramService tg;
  late _FakeChannelTransport transport;
  late ChannelService channelService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_channel_test_');
    db = LocalDbService();
    await db.init(customPath: tempDir.path);
    await db.open(Uint8List.fromList(List.generate(32, (i) => i + 1)));

    transport = _FakeChannelTransport();
    final store = _InMemoryStore();
    tg = TelegramService(transport: transport, credentialStore: store);
    await tg.saveApiCredentials(12345, 'dummy_hash');

    final readyFuture = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.ready);
    await tg.start(databaseDirectory: tempDir.path, filesDirectory: tempDir.path);
    await readyFuture;

    channelService = ChannelService(
      telegramService: tg,
      localDbService: db,
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

  test('syncChannels fetches only Telegram channels and ignores DMs/groups', () async {
    final channels = await channelService.syncChannels();

    expect(channels.length, 2);
    expect(channels.map((c) => c.title).toList(), containsAll(['Vault Main', 'Vault Backup']));
    expect(channelService.getSavedChannels().length, 2);
  });

  test('Select Primary & Backup channels and prevent choosing same channel for both', () async {
    final channels = await channelService.syncChannels();
    final mainCh = channels.firstWhere((c) => c.title == 'Vault Main');
    final backupCh = channels.firstWhere((c) => c.title == 'Vault Backup');

    await channelService.setPrimaryChannel(mainCh);
    expect(channelService.getPrimaryChannel()?.chatId, mainCh.chatId);

    // Same channel backup nahi ban sakta
    await expectLater(
      () => channelService.setBackupChannel(mainCh),
      throwsArgumentError,
    );

    await channelService.setBackupChannel(backupCh);
    expect(channelService.getBackupChannel()?.chatId, backupCh.chatId);

    // Re-sync par Primary/Backup selection barkarar rehni chahiye
    transport.chats[-1001111111]!['title'] = 'Vault Main Renamed';
    await channelService.syncChannels();

    expect(channelService.getPrimaryChannel()?.title, 'Vault Main Renamed');
    expect(channelService.getBackupChannel()?.chatId, backupCh.chatId);
  });

  test('createPrivateChannel creates channel via TDLib and sets it as Primary', () async {
    final created = await channelService.createPrivateChannel(
      title: 'My Secret Vault',
      setAsPrimary: true,
    );

    expect(created.title, 'My Secret Vault');
    expect(created.isPrimary, isTrue);
    expect(channelService.getPrimaryChannel()?.chatId, created.chatId);
  });
}