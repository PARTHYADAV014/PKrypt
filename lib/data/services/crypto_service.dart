import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:argon2/argon2.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/foundation.dart';

class CryptoService {
  static const List<int> _magicHeader = [0x56, 0x41, 0x55, 0x4C]; // "VAUL"
  static const List<int> _zkMagicHeader = [0x56, 0x47, 0x5A, 0x31]; // "VGZ1"
  static const int _version = 1;
  static const int _isolateThresholdBytes = 64 * 1024; // 64 KB
  static const String _recoveryAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // Always resolve through Cryptography.instance so FlutterCryptography is used
  static AesGcm get _aesGcm => AesGcm.with256bits();
  static X25519 get _x25519 => X25519();
  static Hkdf get _hkdf => Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// True when native platform crypto (Android/iOS/macOS) is active.
  /// Native AES-GCM runs asynchronously via platform channels on hardware engines,
  /// whereas spawned Dart isolates only have pure-Dart fallback.
  static bool get isHardwareCryptoActive =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) &&
      Cryptography.instance is FlutterCryptography;

  // Active key jo encrypt/decrypt mein use hoti hai (DEK ya derived key)
  SecretKey? _masterKey;
  Uint8List? _masterKeyRaw;

  // Optional separate DEK slot jab KEK/DEK wrapping mode active ho
  SecretKey? _dekKey;
  Uint8List? _dekRaw;

  // X25519 asymmetric keypair for Zero-Knowledge locked background uploads
  SimpleKeyPairData? _x25519KeyPair;
  Uint8List? _x25519PrivRaw;
  Uint8List? _x25519PubRaw;

  bool get isUnlocked => _masterKey != null || _dekKey != null;
  bool get hasX25519KeyPair => _x25519KeyPair != null;

  // Background thread (Isolate) mein run hoga taaki UI hang na ho
  static Uint8List _computeArgon2Key(String password, Uint8List salt) {
    final argon2 = Argon2BytesGenerator();
    final params = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      version: Argon2Parameters.ARGON2_VERSION_13,
      iterations: 3,
      memory: 65536, // 64 MB
      lanes: 4,
    );
    argon2.init(params);

    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    final keyBytes = Uint8List(32);
    argon2.generateBytes(passwordBytes, keyBytes);
    _zeroBytes(passwordBytes);
    return keyBytes;
  }

  // 1. Password se master/KEK key banao (Argon2id)
  Future<void> deriveKey(String password, Uint8List salt) async {
    final keyBytes = await Isolate.run(
      () => _computeArgon2Key(password, salt),
    );
    loadMasterKeyBytes(keyBytes);
  }

  // Biometric unlock ke baad seedha key load karne ke liye
  void loadMasterKeyBytes(Uint8List keyBytes) {
    if (keyBytes.length != 32) {
      throw ArgumentError('Master key must be 32 bytes');
    }
    _clearKeyBuffer(_masterKeyRaw);
    final copy = Uint8List.fromList(keyBytes);
    _masterKeyRaw = copy;
    _masterKey = SecretKey(Uint8List.fromList(copy));
  }

  // Biometric storage aur encrypted Hive DB ke liye key nikalna
  Future<Uint8List> exportMasterKeyBytes() async {
    if (_dekRaw != null) {
      return Uint8List.fromList(_dekRaw!);
    }
    if (_masterKeyRaw != null) {
      return Uint8List.fromList(_masterKeyRaw!);
    }
    if (_masterKey == null) throw Exception('Key not derived');
    final bytes = await _masterKey!.extractBytes();
    return Uint8List.fromList(bytes);
  }

  // Naya random salt banane ke liye
  Uint8List generateSalt([int length = 16]) {
    return _generateSecureRandomBytes(length);
  }

  // Nayi 32-byte Data Encryption Key (DEK) banao
  Uint8List generateDek() {
    return _generateSecureRandomBytes(32);
  }

  // Active DEK set karo (data encryption/decryption is DEK se hoga)
  void setActiveDek(Uint8List dekBytes) {
    if (dekBytes.length != 32) {
      throw ArgumentError('DEK must be 32 bytes');
    }
    _clearKeyBuffer(_dekRaw);
    final copy = Uint8List.fromList(dekBytes);
    _dekRaw = copy;
    _dekKey = SecretKey(Uint8List.fromList(copy));
  }

  // ---------------- X25519 ZERO-KNOWLEDGE LAYER ----------------

  Future<({Uint8List publicKey, Uint8List privateKey})>
      generateX25519KeyPair() async {
    final kp = await _x25519.newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (publicKey: pub, privateKey: priv);
  }

  void setX25519KeyPair({
    required Uint8List privateKeyBytes,
    required Uint8List publicKeyBytes,
  }) {
    if (privateKeyBytes.length != 32 || publicKeyBytes.length != 32) {
      throw ArgumentError('X25519 keys must be 32 bytes');
    }
    _clearKeyBuffer(_x25519PrivRaw);
    _x25519PrivRaw = Uint8List.fromList(privateKeyBytes);
    _x25519PubRaw = Uint8List.fromList(publicKeyBytes);
    _x25519KeyPair = SimpleKeyPairData(
      Uint8List.fromList(privateKeyBytes),
      publicKey: SimplePublicKey(
        Uint8List.fromList(publicKeyBytes),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
  }

  Uint8List? get x25519PublicKeyBytes =>
      _x25519PubRaw != null ? Uint8List.fromList(_x25519PubRaw!) : null;

  /// Lock-only encryption for background uploads (works even when vault is LOCKED).
  Future<Uint8List> encryptForPublicKey({
    required Uint8List plaintext,
    required Uint8List recipientPublicKeyBytes,
  }) async {
    if (recipientPublicKeyBytes.length != 32) {
      throw ArgumentError('Recipient X25519 public key must be 32 bytes');
    }

    if (!isHardwareCryptoActive && plaintext.length >= _isolateThresholdBytes) {
      final payload = TransferableTypedData.fromList([plaintext]);
      final pubCopy = Uint8List.fromList(recipientPublicKeyBytes);
      final result = await Isolate.run(
        () => _encryptZkIsolate(payload, pubCopy),
      );
      return result.materialize().asUint8List();
    }

    return _encryptZkBytes(
      plaintext: plaintext,
      recipientPublicKeyBytes: recipientPublicKeyBytes,
    );
  }

  Future<Uint8List> _decryptZkPayload(Uint8List encrypted) async {
    if (_x25519KeyPair == null) {
      throw StateError('X25519 private key is not loaded. Unlock vault first.');
    }

    final privCopy = _x25519PrivRaw != null
        ? Uint8List.fromList(_x25519PrivRaw!)
        : Uint8List.fromList(await _x25519KeyPair!.extractPrivateKeyBytes());
    final pubCopy = _x25519PubRaw != null
        ? Uint8List.fromList(_x25519PubRaw!)
        : Uint8List.fromList((await _x25519KeyPair!.extractPublicKey()).bytes);

    try {
      if (!isHardwareCryptoActive &&
          encrypted.length >= _isolateThresholdBytes) {
        final payload = TransferableTypedData.fromList([encrypted]);
        final result = await Isolate.run(
          () => _decryptZkIsolate(payload, privCopy, pubCopy),
        );
        return result.materialize().asUint8List();
      }

      return await _decryptZkBytes(
        encrypted: encrypted,
        privateKeyBytes: privCopy,
        publicKeyBytes: pubCopy,
      );
    } finally {
      _zeroBytes(privCopy);
    }
  }

  // ---------------- KEY WRAPPING & RECOVERY ----------------

  Future<Uint8List> wrapKey({
    required Uint8List keyToWrap,
    required Uint8List wrappingKeyBytes,
  }) async {
    if (keyToWrap.length != 32 || wrappingKeyBytes.length != 32) {
      throw ArgumentError('Wrap keys must be 32 bytes');
    }
    return _encryptSymmetricBytes(
      plaintext: keyToWrap,
      keyBytes: wrappingKeyBytes,
    );
  }

  Future<Uint8List> unwrapKey({
    required Uint8List wrappedKeyPayload,
    required Uint8List wrappingKeyBytes,
  }) async {
    if (wrappingKeyBytes.length != 32) {
      throw ArgumentError('Wrapping key must be 32 bytes');
    }
    return _decryptSymmetricBytes(
      encrypted: wrappedKeyPayload,
      keyBytes: wrappingKeyBytes,
    );
  }

  Future<Uint8List> rewrapDekForNewPassword({
    required Uint8List wrappedDekPayload,
    required String oldPassword,
    required Uint8List oldSalt,
    required String newPassword,
    required Uint8List newSalt,
  }) async {
    final oldKek = await Isolate.run(
      () => _computeArgon2Key(oldPassword, oldSalt),
    );
    Uint8List? dek;
    Uint8List? newKek;
    try {
      dek = await unwrapKey(
        wrappedKeyPayload: wrappedDekPayload,
        wrappingKeyBytes: oldKek,
      );
      newKek = await Isolate.run<Uint8List>(
        () => _computeArgon2Key(newPassword, newSalt),
      );
      return await wrapKey(
        keyToWrap: dek,
        wrappingKeyBytes: newKek,
      );
    } finally {
      _zeroBytes(oldKek);
      if (newKek != null) _zeroBytes(newKek);
      if (dek != null) _zeroBytes(dek);
    }
  }

  String generateRecoveryKey() {
    final random = Random.secure();
    final chars = List.generate(
      24,
      (_) => _recoveryAlphabet[random.nextInt(_recoveryAlphabet.length)],
    );
    final groups = <String>[];
    for (int i = 0; i < chars.length; i += 4) {
      groups.add(chars.sublist(i, i + 4).join());
    }
    return groups.join('-');
  }

  Future<Uint8List> deriveRecoveryWrappingKey(
    String recoveryKey,
    Uint8List salt,
  ) async {
    final normalized = recoveryKey.replaceAll('-', '').trim().toUpperCase();
    return Isolate.run(() => _computeArgon2Key(normalized, salt));
  }

  // 2. Photo/Data Encrypt karo (Native Hardware AES-GCM on mobile, Isolate fallback elsewhere)
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final keyCopy = await _getActiveKeyBytesCopy();
    try {
      if (!isHardwareCryptoActive &&
          plaintext.length >= _isolateThresholdBytes) {
        final payload = TransferableTypedData.fromList([plaintext]);
        final result = await Isolate.run(
          () => _encryptSymmetricIsolate(payload, keyCopy),
        );
        return result.materialize().asUint8List();
      }
      return await _encryptSymmetricBytes(
        plaintext: plaintext,
        keyBytes: keyCopy,
      );
    } finally {
      _zeroBytes(keyCopy);
    }
  }

  // 3. Photo/Data Decrypt karo (Auto-detects VAUL symmetric or VGZ1 X25519)
  Future<Uint8List> decrypt(Uint8List encrypted) async {
    if (_hasHeader(encrypted, _zkMagicHeader)) {
      return _decryptZkPayload(encrypted);
    }

    final keyCopy = await _getActiveKeyBytesCopy();
    try {
      if (!isHardwareCryptoActive &&
          encrypted.length >= _isolateThresholdBytes) {
        final payload = TransferableTypedData.fromList([encrypted]);
        final result = await Isolate.run(
          () => _decryptSymmetricIsolate(payload, keyCopy),
        );
        return result.materialize().asUint8List();
      }
      return await _decryptSymmetricBytes(
        encrypted: encrypted,
        keyBytes: keyCopy,
      );
    } finally {
      _zeroBytes(keyCopy);
    }
  }

  Future<Uint8List> _getActiveKeyBytesCopy() async {
    if (_dekRaw != null) {
      return Uint8List.fromList(_dekRaw!);
    }
    if (_masterKeyRaw != null) {
      return Uint8List.fromList(_masterKeyRaw!);
    }
    final activeKey = _dekKey ?? _masterKey;
    if (activeKey == null) throw Exception('Key not derived');
    final bytes = await activeKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  // ---------------- ISOLATE WORKERS & STATIC PRIMITIVES ----------------

  static Future<TransferableTypedData> _encryptSymmetricIsolate(
    TransferableTypedData plaintextTransfer,
    Uint8List keyBytes,
  ) async {
    try {
      final plaintext = plaintextTransfer.materialize().asUint8List();
      final encrypted = await _encryptSymmetricBytes(
        plaintext: plaintext,
        keyBytes: keyBytes,
      );
      return TransferableTypedData.fromList([encrypted]);
    } finally {
      _zeroBytes(keyBytes);
    }
  }

  static Future<TransferableTypedData> _decryptSymmetricIsolate(
    TransferableTypedData encryptedTransfer,
    Uint8List keyBytes,
  ) async {
    try {
      final encrypted = encryptedTransfer.materialize().asUint8List();
      final plain = await _decryptSymmetricBytes(
        encrypted: encrypted,
        keyBytes: keyBytes,
      );
      return TransferableTypedData.fromList([plain]);
    } finally {
      _zeroBytes(keyBytes);
    }
  }

  static Future<TransferableTypedData> _encryptZkIsolate(
    TransferableTypedData plaintextTransfer,
    Uint8List recipientPublicKeyBytes,
  ) async {
    final plaintext = plaintextTransfer.materialize().asUint8List();
    final encrypted = await _encryptZkBytes(
      plaintext: plaintext,
      recipientPublicKeyBytes: recipientPublicKeyBytes,
    );
    return TransferableTypedData.fromList([encrypted]);
  }

  static Future<TransferableTypedData> _decryptZkIsolate(
    TransferableTypedData encryptedTransfer,
    Uint8List privateKeyBytes,
    Uint8List publicKeyBytes,
  ) async {
    try {
      final encrypted = encryptedTransfer.materialize().asUint8List();
      final plain = await _decryptZkBytes(
        encrypted: encrypted,
        privateKeyBytes: privateKeyBytes,
        publicKeyBytes: publicKeyBytes,
      );
      return TransferableTypedData.fromList([plain]);
    } finally {
      _zeroBytes(privateKeyBytes);
    }
  }

  static Future<Uint8List> _encryptSymmetricBytes({
    required Uint8List plaintext,
    required Uint8List keyBytes,
  }) async {
    final key = SecretKey(Uint8List.fromList(keyBytes));
    final nonce = _generateSecureRandomBytes(12);
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    return _packVaultPayload(
      nonce: nonce,
      cipherText: secretBox.cipherText,
      macBytes: secretBox.mac.bytes,
    );
  }

  static Future<Uint8List> _decryptSymmetricBytes({
    required Uint8List encrypted,
    required Uint8List keyBytes,
  }) async {
    final key = SecretKey(Uint8List.fromList(keyBytes));
    final unpacked = _unpackVaultPayload(encrypted);
    final box = SecretBox(
      unpacked.cipherText,
      nonce: unpacked.nonce,
      mac: Mac(unpacked.macBytes),
    );
    final plain = await _aesGcm.decrypt(box, secretKey: key);
    return Uint8List.fromList(plain);
  }

  static Future<Uint8List> _encryptZkBytes({
    required Uint8List plaintext,
    required Uint8List recipientPublicKeyBytes,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPubBytes =
        Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipientPublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: ephemeralPubBytes,
      info: utf8.encode('VGZ1'),
    );

    final nonce = _generateSecureRandomBytes(12);
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: aesKey,
      nonce: nonce,
    );

    // Format: [VGZ1(4) | VER(1) | EPHEMERAL_PUB(32) | NONCE(12) | CIPHER | MAC(16)]
    final builder = BytesBuilder(copy: false);
    builder.add(_zkMagicHeader);
    builder.add([_version]);
    builder.add(ephemeralPubBytes);
    builder.add(nonce);
    builder.add(secretBox.cipherText);
    builder.add(secretBox.mac.bytes);
    return builder.takeBytes();
  }

  static Future<Uint8List> _decryptZkBytes({
    required Uint8List encrypted,
    required Uint8List privateKeyBytes,
    required Uint8List publicKeyBytes,
  }) async {
    // Min size: 4 (magic) + 1 (ver) + 32 (ephPub) + 12 (nonce) + 16 (mac) = 65
    if (encrypted.length < 65) {
      throw const FormatException('Encrypted VGZ1 data too short or corrupted');
    }
    if (encrypted[4] != _version) {
      throw FormatException('Unsupported VGZ1 version: ${encrypted[4]}');
    }

    final ephemeralPubBytes = encrypted.sublist(5, 37);
    final nonce = encrypted.sublist(37, 49);
    final cipherText = encrypted.sublist(49, encrypted.length - 16);
    final macBytes = encrypted.sublist(encrypted.length - 16);

    final keyPair = SimpleKeyPairData(
      Uint8List.fromList(privateKeyBytes),
      publicKey: SimplePublicKey(
        Uint8List.fromList(publicKeyBytes),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        ephemeralPubBytes,
        type: KeyPairType.x25519,
      ),
    );
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: ephemeralPubBytes,
      info: utf8.encode('VGZ1'),
    );

    final box = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );
    final plain = await _aesGcm.decrypt(box, secretKey: aesKey);
    return Uint8List.fromList(plain);
  }

  static bool _hasHeader(Uint8List data, List<int> header) {
    if (data.length < header.length) return false;
    for (int i = 0; i < header.length; i++) {
      if (data[i] != header[i]) return false;
    }
    return true;
  }

  static Uint8List _packVaultPayload({
    required Uint8List nonce,
    required List<int> cipherText,
    required List<int> macBytes,
  }) {
    final builder = BytesBuilder(copy: false);
    builder.add(_magicHeader);
    builder.add([_version]);
    builder.add(nonce);
    builder.add(cipherText);
    builder.add(macBytes);
    return builder.takeBytes();
  }

  static _UnpackedVaultPayload _unpackVaultPayload(Uint8List encrypted) {
    if (encrypted.length < 33) {
      throw const FormatException('Encrypted data too short or corrupted');
    }

    if (!_hasHeader(encrypted, _magicHeader)) {
      throw const FormatException('Invalid vault file header');
    }

    if (encrypted[4] != _version) {
      throw FormatException('Unsupported vault version: ${encrypted[4]}');
    }

    return _UnpackedVaultPayload(
      nonce: encrypted.sublist(5, 17),
      cipherText: encrypted.sublist(17, encrypted.length - 16),
      macBytes: encrypted.sublist(encrypted.length - 16),
    );
  }

  static Uint8List _generateSecureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  void _clearKeyBuffer(Uint8List? buffer) {
    if (buffer != null) {
      _zeroBytes(buffer);
    }
  }

  static void _zeroBytes(Uint8List bytes) {
    bytes.fillRange(0, bytes.length, 0);
  }

  // 4. Lock pe saari key bytes RAM se zero karke delete karo
  void clearKey() {
    _clearKeyBuffer(_masterKeyRaw);
    _masterKeyRaw = null;
    _masterKey = null;

    _clearKeyBuffer(_dekRaw);
    _dekRaw = null;
    _dekKey = null;

    _clearKeyBuffer(_x25519PrivRaw);
    _x25519PrivRaw = null;
    _x25519PubRaw = null;
    _x25519KeyPair = null;
  }
}

class _UnpackedVaultPayload {
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List macBytes;

  const _UnpackedVaultPayload({
    required this.nonce,
    required this.cipherText,
    required this.macBytes,
  });
}