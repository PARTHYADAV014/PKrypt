import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/telegram_config.dart';

typedef TdEvent = Map<String, dynamic>;

typedef _TdCreateClientIdNative = Int32 Function();
typedef _TdCreateClientIdDart = int Function();

typedef _TdSendNative = Void Function(Int32 clientId, Pointer<Utf8> request);
typedef _TdSendDart = void Function(int clientId, Pointer<Utf8> request);

typedef _TdReceiveNative = Pointer<Utf8> Function(Double timeout);
typedef _TdReceiveDart = Pointer<Utf8> Function(double timeout);

typedef _TdExecuteNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _TdExecuteDart = Pointer<Utf8> Function(Pointer<Utf8> request);

enum TelegramAuthState {
  initializing,
  waitPhoneNumber,
  waitCode,
  waitPassword,
  ready,
  loggedOut,
}

void _tdReceiveIsolate(SendPort sendPort) {
  final lib = DynamicLibrary.open('libtdjson.so');
  final tdReceive =
      lib.lookupFunction<_TdReceiveNative, _TdReceiveDart>('td_receive');

  while (true) {
    final ptr = tdReceive(1.0);
    if (ptr != nullptr) {
      sendPort.send(ptr.toDartString());
    }
  }
}

class TdlibService {
  TdlibService._();
  static final TdlibService instance = TdlibService._();

  DynamicLibrary? _lib;
  late _TdCreateClientIdDart _tdCreateClientId;
  late _TdSendDart _tdSend;
  late _TdExecuteDart _tdExecute;

  int? _clientId;
  bool _isInitialized = false;
  ReceivePort? _receivePort;
  Isolate? _isolate;

  final _authController = StreamController<TelegramAuthState>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _rawEventController = StreamController<TdEvent>.broadcast();

  TelegramAuthState currentState = TelegramAuthState.initializing;
  String passwordHint = '';

  Stream<TelegramAuthState> get authStateStream => _authController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<TdEvent> get rawEventStream => _rawEventController.stream;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    _lib = DynamicLibrary.open('libtdjson.so');
    _tdCreateClientId = _lib!.lookupFunction<_TdCreateClientIdNative,
        _TdCreateClientIdDart>('td_create_client_id');
    _tdSend = _lib!.lookupFunction<_TdSendNative, _TdSendDart>('td_send');
    _tdExecute =
        _lib!.lookupFunction<_TdExecuteNative, _TdExecuteDart>('td_execute');

    _execute({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1});

    _clientId = _tdCreateClientId();

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is String) {
        _handleIncomingJson(message);
      }
    });

    _isolate = await Isolate.spawn(_tdReceiveIsolate, _receivePort!.sendPort);

    send({'@type': 'getAuthorizationState'});
  }

  void _execute(TdEvent request) {
    final ptr = jsonEncode(request).toNativeUtf8();
    try {
      _tdExecute(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  void send(TdEvent request) {
    if (_clientId == null) return;
    final ptr = jsonEncode(request).toNativeUtf8();
    try {
      _tdSend(_clientId!, ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  void _handleIncomingJson(String raw) {
    final TdEvent data = jsonDecode(raw) as TdEvent;
    _rawEventController.add(data);

    final type = data['@type'];

    if (type == 'error') {
      final msg = data['message']?.toString() ?? 'Telegram error';
      _errorController.add(msg);
      return;
    }

    if (type == 'updateAuthorizationState') {
      final authState = data['authorization_state'] as TdEvent?;
      final stateType = authState?['@type'];

      switch (stateType) {
        case 'authorizationStateWaitTdlibParameters':
          _sendTdlibParameters();
          break;
        case 'authorizationStateWaitPhoneNumber':
          _updateState(TelegramAuthState.waitPhoneNumber);
          break;
        case 'authorizationStateWaitCode':
          _updateState(TelegramAuthState.waitCode);
          break;
        case 'authorizationStateWaitPassword':
          passwordHint = authState?['password_hint']?.toString() ?? '';
          _updateState(TelegramAuthState.waitPassword);
          break;
        case 'authorizationStateReady':
          _updateState(TelegramAuthState.ready);
          break;
        case 'authorizationStateClosed':
        case 'authorizationStateLoggingOut':
          _updateState(TelegramAuthState.loggedOut);
          break;
      }
    }
  }

  void _updateState(TelegramAuthState newState) {
    currentState = newState;
    _authController.add(newState);
  }

  Future<void> _sendTdlibParameters() async {
    if (TelegramConfig.apiId == 0 ||
        TelegramConfig.apiHash == 'YOUR_API_HASH') {
      _errorController
          .add('Please add your api_id and api_hash in telegram_config.dart!');
      return;
    }

    final dir = await getApplicationSupportDirectory();
    send({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': '${dir.path}/tdlib_db',
      'files_directory': '${dir.path}/tdlib_files',
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': TelegramConfig.apiId,
      'api_hash': TelegramConfig.apiHash,
      'system_language_code': 'en',
      'device_model': 'Android',
      'system_version': 'Android',
      'application_version': '1.0.0',
    });
  }

  void sendPhoneNumber(String phone) {
    send({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phone.trim(),
    });
  }

  void sendOtpCode(String code) {
    send({
      '@type': 'checkAuthenticationCode',
      'code': code.trim(),
    });
  }

  void send2FaPassword(String password) {
    send({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
  }
}