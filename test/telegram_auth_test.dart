import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
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

class _FakeTdlibTransport implements TdlibTransport {
  final _controller = StreamController<JsonMap>.broadcast();
  final List<JsonMap> sentRequests = [];

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
    sentRequests.add(request);
    final type = request['@type'];
    final extra = request['@extra'];

    if (type == 'getAuthorizationState') {
      _emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {
          '@type': 'authorizationStateWaitTdlibParameters',
        },
      });
    } else if (type == 'setTdlibParameters') {
      _emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {
          '@type': 'authorizationStateWaitPhoneNumber',
        },
      });
    } else if (type == 'setAuthenticationPhoneNumber') {
      _emit({'@type': 'ok', '@extra': extra});
      _emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {
          '@type': 'authorizationStateWaitCode',
        },
      });
    } else if (type == 'checkAuthenticationCode') {
      if (request['code'] == '12345') {
        _emit({'@type': 'ok', '@extra': extra});
        _emit({
          '@type': 'updateAuthorizationState',
          'authorization_state': {
            '@type': 'authorizationStateWaitPassword',
            'password_hint': 'vault_hint',
          },
        });
      } else {
        _emit({
          '@type': 'error',
          'code': 400,
          'message': 'PHONE_CODE_INVALID',
          '@extra': extra,
        });
      }
    } else if (type == 'checkAuthenticationPassword') {
      _emit({'@type': 'ok', '@extra': extra});
      _emit({
        '@type': 'updateAuthorizationState',
        'authorization_state': {
          '@type': 'authorizationStateReady',
        },
      });
    }
  }

  @override
  Future<void> stop() async {
    await _controller.close();
  }
}

void main() {
  test('Save and read Telegram API credentials securely', () async {
    final store = _InMemoryStore();
    final tg = TelegramService(
      transport: _FakeTdlibTransport(),
      credentialStore: store,
    );

    expect(await tg.getSavedApiCredentials(), isNull);

    await tg.saveApiCredentials(12345678, 'abcdef1234567890abcdef1234567890');
    final saved = await tg.getSavedApiCredentials();

    expect(saved?.apiId, 12345678);
    expect(saved?.apiHash, 'abcdef1234567890abcdef1234567890');
    await tg.dispose();
  });

  test('Full Telegram OTP + 2FA login flow reaches ready state', () async {
    final store = _InMemoryStore();
    final transport = _FakeTdlibTransport();
    final tg = TelegramService(transport: transport, credentialStore: store);

    await tg.saveApiCredentials(99999, 'test_hash_123');

    final waitPhoneFuture = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.waitingPhoneNumber);

    await tg.start(
      databaseDirectory: '/tmp/tdlib_db',
      filesDirectory: '/tmp/tdlib_files',
    );
    await waitPhoneFuture;

    // 1. Phone number bhejo
    final waitCodeFuture = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.waitingCode);
    await tg.submitPhoneNumber('+919876543210');
    await waitCodeFuture;

    // 2. Galat OTP par clean TelegramApiException aana chahiye
    await expectLater(
      () => tg.submitOtpCode('00000'),
      throwsA(
        isA<TelegramApiException>()
            .having((e) => e.message, 'message', 'PHONE_CODE_INVALID'),
      ),
    );

    // 3. Sahi OTP bhejo -> 2FA password state aayegi
    final waitPassFuture = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.waitingPassword);
    await tg.submitOtpCode('12345');
    await waitPassFuture;
    expect(tg.passwordHint, 'vault_hint');

    // 4. 2FA password bhejo -> Ready state
    final readyFuture = tg.authStatusStream
        .firstWhere((s) => s == TelegramAuthStatus.ready);
    await tg.submitTwoFactorPassword('my_2fa_pass');
    await readyFuture;

    expect(tg.isReady, isTrue);
    await tg.dispose();
  });
}