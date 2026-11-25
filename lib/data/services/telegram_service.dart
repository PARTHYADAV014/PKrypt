import 'dart:async';
import '../../core/telegram_config.dart';
import 'auth_service.dart';
import 'tdlib_transport.dart';

enum TelegramAuthStatus {
  uninitialized,
  waitingParameters,
  waitingPhoneNumber,
  waitingCode,
  waitingPassword,
  ready,
  loggingOut,
  closed,
}

class TelegramApiCredentials {
  final int apiId;
  final String apiHash;

  const TelegramApiCredentials({
    required this.apiId,
    required this.apiHash,
  });
}

class TelegramApiException implements Exception {
  final int code;
  final String message;

  const TelegramApiException(this.code, this.message);

  @override
  String toString() => 'TelegramApiException($code):$message';
}

class TelegramService {
  static const String _apiIdKey = 'tg_api_id_v1';
  static const String _apiHashKey = 'tg_api_hash_v1';

  final TdlibTransport _transport;
  final KeyValueStore _credentialStore;

  final _authStatusController =
      StreamController<TelegramAuthStatus>.broadcast();
  final _rawUpdatesController = StreamController<JsonMap>.broadcast();
  final Map<String, Completer<JsonMap>> _pendingRequests = {};

  StreamSubscription<JsonMap>? _transportSub;
  TelegramAuthStatus _authStatus = TelegramAuthStatus.uninitialized;
  String? _passwordHint;
  String? _databaseDir;
  String? _filesDir;
  TelegramApiCredentials? _activeCredentials;
  int _requestCounter = 0;
  bool _transportStarted = false;
  Future<void>? _startFuture;
  bool _paramsSent = false;
  bool _isDisposed = false;

  TelegramService({
    TdlibTransport? transport,
    KeyValueStore? credentialStore,
  })  : _transport = transport ?? FfiTdlibTransport(),
        _credentialStore =
            credentialStore ?? const FlutterSecureKeyValueStore();

  TelegramAuthStatus get authStatus => _authStatus;
  Stream<TelegramAuthStatus> get authStatusStream =>
      _authStatusController.stream;
  Stream<JsonMap> get updates => _rawUpdatesController.stream;
  String? get passwordHint => _passwordHint;
  bool get isReady => _authStatus == TelegramAuthStatus.ready;

  Future<void> saveApiCredentials(int apiId, String apiHash) async {
    if (apiId <= 0 || apiHash.trim().isEmpty) {
      throw ArgumentError('Valid Telegram API ID and API Hash are required.');
    }
    await _credentialStore.write(_apiIdKey, apiId.toString());
    await _credentialStore.write(_apiHashKey, apiHash.trim());
  }

  Future<TelegramApiCredentials?> getSavedApiCredentials() async {
    final idRaw = await _credentialStore.read(_apiIdKey);
    final hash = await _credentialStore.read(_apiHashKey);
    if (idRaw != null && hash != null && hash.isNotEmpty) {
      final id = int.tryParse(idRaw);
      if (id != null && id > 0) {
        return TelegramApiCredentials(apiId: id, apiHash: hash);
      }
    }

    // Fallback to built-in TelegramConfig so user never has to re-enter keys
    final cfgHash = TelegramConfig.apiHash.trim();
    if (TelegramConfig.apiId > 0 &&
        cfgHash.isNotEmpty &&
        cfgHash != 'YOUR_API_HASH') {
      return TelegramApiCredentials(
        apiId: TelegramConfig.apiId,
        apiHash: cfgHash,
      );
    }
    return null;
  }

  Future<void> clearApiCredentials() async {
    await _credentialStore.delete(_apiIdKey);
    await _credentialStore.delete(_apiHashKey);
  }

  Future<void> start({
    required String databaseDirectory,
    required String filesDirectory,
    TelegramApiCredentials? credentials,
  }) async {
    final creds = credentials ?? await getSavedApiCredentials();
    if (creds == null) {
      throw StateError(
        'Telegram API keys are missing. Please configure telegram_config.dart.',
      );
    }

    _activeCredentials = creds;
    _databaseDir = databaseDirectory;
    _filesDir = filesDirectory;
    _paramsSent = false;

    if (!_transportStarted) {
      _transportSub ??= _transport.updates.listen(_handleEvent);
      _startFuture ??= _transport.start();
      try {
        await _startFuture;
        _transportStarted = true;
      } finally {
        _startFuture = null;
      }
    }

    if (_authStatus == TelegramAuthStatus.waitingParameters) {
      _sendTdlibParameters();
    } else {
      _transport.send({'@type': 'getAuthorizationState'});
    }
  }

  void _handleEvent(JsonMap event) {
    if (_isDisposed) return;

    final extra = event['@extra'];
    if (extra is String && _pendingRequests.containsKey(extra)) {
      final completer = _pendingRequests.remove(extra)!;
      if (!completer.isCompleted) {
        if (event['@type'] == 'error') {
          completer.completeError(
            TelegramApiException(
              (event['code'] as int?) ?? -1,
              (event['message'] as String?) ?? 'Unknown TDLib error',
            ),
          );
        } else {
          completer.complete(event);
        }
      }
    }

    final type = event['@type'] as String?;
    if (type == 'updateAuthorizationState') {
      final state = event['authorization_state'];
      if (state is JsonMap) {
        _handleAuthorizationState(state);
      }
    } else if (type != null && type.startsWith('authorizationState')) {
      _handleAuthorizationState(event);
    }

    if (!_rawUpdatesController.isClosed) {
      _rawUpdatesController.add(event);
    }
  }

  void _handleAuthorizationState(JsonMap state) {
    final type = state['@type'] as String?;

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _setStatus(TelegramAuthStatus.waitingParameters);
        if (!_paramsSent) {
          _sendTdlibParameters();
        }
        break;
      case 'authorizationStateWaitPhoneNumber':
        _setStatus(TelegramAuthStatus.waitingPhoneNumber);
        break;
      case 'authorizationStateWaitCode':
        _setStatus(TelegramAuthStatus.waitingCode);
        break;
      case 'authorizationStateWaitPassword':
        _passwordHint = state['password_hint'] as String?;
        _setStatus(TelegramAuthStatus.waitingPassword);
        break;
      case 'authorizationStateReady':
        _passwordHint = null;
        _setStatus(TelegramAuthStatus.ready);
        break;
      case 'authorizationStateLoggingOut':
        _setStatus(TelegramAuthStatus.loggingOut);
        break;
      case 'authorizationStateClosed':
        _paramsSent = false;
        _transportStarted = false;
        _setStatus(TelegramAuthStatus.closed);
        break;
    }
  }

  void _setStatus(TelegramAuthStatus status) {
    _authStatus = status;
    if (!_authStatusController.isClosed) {
      _authStatusController.add(status);
    }
  }

  void _sendTdlibParameters() {
    final creds = _activeCredentials;
    if (creds == null ||
        _databaseDir == null ||
        _filesDir == null ||
        _paramsSent) {
      return;
    }

    _paramsSent = true;
    sendRequest({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': _databaseDir,
      'files_directory': _filesDir,
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': creds.apiId,
      'api_hash': creds.apiHash,
      'system_language_code': 'en',
      'device_model': 'Pkrypt Android',
      'system_version': 'Android',
      'application_version': '1.0.0',
    }).then<void>(
      (_) {},
      onError: (_) {
        _paramsSent = false;
      },
    );
  }

  Future<void> submitPhoneNumber(String phoneNumber) async {
    await sendRequest({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber.trim(),
    });
  }

  Future<void> submitOtpCode(String code) async {
    await sendRequest({
      '@type': 'checkAuthenticationCode',
      'code': code.trim(),
    });
  }

  Future<void> submitTwoFactorPassword(String password) async {
    await sendRequest({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
  }

  Future<void> logout() async {
    await sendRequest({'@type': 'logOut'});
  }

  Future<JsonMap> sendRequest(
    JsonMap request, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_isDisposed) {
      return Future.error(StateError('TelegramService is disposed'));
    }

    final extra = 'req_${++_requestCounter}';
    final completer = Completer<JsonMap>();
    _pendingRequests[extra] = completer;

    final payload = <String, dynamic>{...request, '@extra': extra};
    _transport.send(payload);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingRequests.remove(extra);
        throw TimeoutException('TDLib request timed out: ${request['@type']}');
      },
    );
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _transportStarted = false;
    _paramsSent = false;
    await _transportSub?.cancel();
    _transportSub = null;
    _pendingRequests.clear();
    await _transport.stop();
    if (!_authStatusController.isClosed) {
      await _authStatusController.close();
    }
    if (!_rawUpdatesController.isClosed) {
      await _rawUpdatesController.close();
    }
  }
}