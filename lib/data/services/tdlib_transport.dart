import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;
import 'package:ffi/ffi.dart';

typedef JsonMap = Map<String, dynamic>;

abstract class TdlibTransport {
  Stream<JsonMap> get updates;
  Future<void> start();
  void send(JsonMap request);
  Future<void> stop();
}

typedef _TdCreateClientIdNative = Int32 Function();
typedef _TdCreateClientIdDart = int Function();

typedef _TdSendNative = Void Function(Int32 clientId, Pointer<Utf8> request);
typedef _TdSendDart = void Function(int clientId, Pointer<Utf8> request);

typedef _TdReceiveNative = Pointer<Utf8> Function(Double timeout);
typedef _TdReceiveDart = Pointer<Utf8> Function(double timeout);

typedef _TdExecuteNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _TdExecuteDart = Pointer<Utf8> Function(Pointer<Utf8> request);

/// Process-wide FFI bridge to libtdjson.so.
/// Guarantees ONLY ONE thread in the OS process ever calls td_receive().
class FfiTdlibTransport implements TdlibTransport {
  static const String _hubPortName = 'pkrypt_tdlib_receive_hub_v1';

  static Future<void>? _globalAttachFuture;
  static bool _globalAttached = false;
  static final StreamController<JsonMap> _globalDecodedStream =
      StreamController<JsonMap>.broadcast();

  final String? customLibraryPath;
  final _updatesController = StreamController<JsonMap>.broadcast();

  DynamicLibrary? _lib;
  _TdSendDart? _tdSend;
  int? _clientId;
  Future<void>? _startFuture;
  StreamSubscription<JsonMap>? _globalSub;

  FfiTdlibTransport({this.customLibraryPath});

  @override
  Stream<JsonMap> get updates => _updatesController.stream;

  String _resolveLibraryPath() {
    if (customLibraryPath != null && customLibraryPath!.isNotEmpty) {
      return customLibraryPath!;
    }
    if (Platform.isAndroid || Platform.isLinux) return 'libtdjson.so';
    if (Platform.isWindows) return 'tdjson.dll';
    if (Platform.isMacOS) return 'libtdjson.dylib';
    return '';
  }

  static DynamicLibrary _openLibrary(String path) {
    if (path.isEmpty) return DynamicLibrary.process();
    return DynamicLibrary.open(path);
  }

  static Future<void> _ensureGlobalReceiveHub(String libPath) {
    if (_globalAttached) return Future<void>.value();
    return _globalAttachFuture ??= _attachOrSpawnHub(libPath);
  }

  static Future<void> _attachOrSpawnHub(String libPath) async {
    try {
      final deliveryPort = ReceivePort();
      deliveryPort.listen((message) {
        if (message is String && !_globalDecodedStream.isClosed) {
          try {
            final decoded = jsonDecode(message);
            if (decoded is JsonMap) {
              _globalDecodedStream.add(decoded);
            }
          } catch (_) {}
        }
      });

      SendPort? existingHub;
      try {
        existingHub = IsolateNameServer.lookupPortByName(_hubPortName);
      } catch (_) {
        existingHub = null;
      }

      if (existingHub != null) {
        existingHub.send(deliveryPort.sendPort);
        _globalAttached = true;
        return;
      }

      final handshakePort = ReceivePort();
      final controlCompleter = Completer<SendPort>();
      handshakePort.listen((msg) {
        if (msg is SendPort && !controlCompleter.isCompleted) {
          controlCompleter.complete(msg);
          handshakePort.close();
        }
      });

      await Isolate.spawn(
        _receiveHubEntry,
        [handshakePort.sendPort, deliveryPort.sendPort, libPath],
      );

      final controlPort = await controlCompleter.future.timeout(
        const Duration(seconds: 5),
      );

      try {
        IsolateNameServer.removePortNameMapping(_hubPortName);
        IsolateNameServer.registerPortWithName(controlPort, _hubPortName);
      } catch (_) {}

      _globalAttached = true;
    } catch (e) {
      _globalAttachFuture = null;
      rethrow;
    }
  }

  @override
  Future<void> start() {
    if (_clientId != null) return Future<void>.value();
    return _startFuture ??= _startInternal();
  }

  Future<void> _startInternal() async {
    try {
      final libPath = _resolveLibraryPath();
      _lib = _openLibrary(libPath);

      final createClientId = _lib!
          .lookupFunction<_TdCreateClientIdNative, _TdCreateClientIdDart>(
              'td_create_client_id');
      _tdSend = _lib!.lookupFunction<_TdSendNative, _TdSendDart>('td_send');
      final tdExecute =
          _lib!.lookupFunction<_TdExecuteNative, _TdExecuteDart>('td_execute');

      final logReq = jsonEncode({
        '@type': 'setLogVerbosityLevel',
        'new_verbosity_level': 1,
      }).toNativeUtf8();
      try {
        tdExecute(logReq);
      } finally {
        malloc.free(logReq);
      }

      _clientId = createClientId();

      _globalSub ??= _globalDecodedStream.stream.listen((decoded) {
        if (_updatesController.isClosed) return;
        final eventClientId = decoded['@client_id'];
        if (eventClientId == null || eventClientId == _clientId) {
          _updatesController.add(decoded);
        }
      });

      await _ensureGlobalReceiveHub(libPath);
    } catch (e) {
      _startFuture = null;
      rethrow;
    }
  }

  static Future<void> _receiveHubEntry(List<dynamic> args) async {
    final handshakePort = args[0] as SendPort;
    final initialSubscriber = args[1] as SendPort;
    final libPath = args[2] as String;

    final subscribers = <SendPort>[initialSubscriber];
    final controlPort = ReceivePort();
    controlPort.listen((msg) {
      if (msg is SendPort) {
        subscribers
          ..clear()
          ..add(msg);
      }
    });

    handshakePort.send(controlPort.sendPort);

    final lib = _openLibrary(libPath);
    final tdReceive =
        lib.lookupFunction<_TdReceiveNative, _TdReceiveDart>('td_receive');

    while (true) {
      var resultPtr = tdReceive(0.15);
      int burst = 0;
      while (resultPtr != nullptr) {
        final text = resultPtr.toDartString();
        for (final sub in List<SendPort>.from(subscribers)) {
          try {
            sub.send(text);
          } catch (_) {}
        }
        burst++;
        if (burst >= 32) break;
        resultPtr = tdReceive(0.0);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  void send(JsonMap request) {
    if (_clientId == null || _tdSend == null) {
      throw StateError('TDLib transport has not been started.');
    }
    final payload = jsonEncode(request).toNativeUtf8();
    try {
      _tdSend!(_clientId!, payload);
    } finally {
      malloc.free(payload);
    }
  }

  @override
  Future<void> stop() async {
    await _globalSub?.cancel();
    _globalSub = null;
    _clientId = null;
    _tdSend = null;
    _startFuture = null;
    if (!_updatesController.isClosed) {
      await _updatesController.close();
    }
  }
}