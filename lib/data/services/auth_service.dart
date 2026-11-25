import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'crypto_service.dart';

enum UnlockMode { none, master, decoy }

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements KeyValueStore {
  final FlutterSecureStorage _storage;

  const FlutterSecureKeyValueStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class AuthService {
  static const String _saltKey = 'vault_salt_v1';
  static const String _verifierKey = 'vault_verifier_v1';
  static const String _wrappedDekKey = 'vault_wrapped_dek_v2';
  static const String _recoverySaltKey = 'vault_recovery_salt_v2';
  static const String _recoveryWrappedDekKey = 'vault_recovery_wrapped_dek_v2';
  static const String _remoteWipeCodeKey = 'vault_remote_wipe_code_v2';
  static const String _biometricEnabledKey = 'vault_biometric_enabled_v1';
  static const String _biometricMasterKey = 'vault_biometric_master_key_v1';
  static const String _x25519PubKey = 'vault_x25519_pub_v1';
  static const String _x25519WrappedPrivKey = 'vault_x25519_wrapped_priv_v1';
  static const String _canaryPlaintext = 'VAULT_GALLERY_OK_V1';

  // Isolated Decoy Vault keys (never exported to Telegram cloud key bundle)
  static const String _decoySaltKey = 'vault_decoy_salt_v1';
  static const String _decoyVerifierKey = 'vault_decoy_verifier_v1';
  static const String _decoyWrappedDekKey = 'vault_decoy_wrapped_dek_v1';
  static const String _decoyCanaryPlaintext = 'VAULT_DECOY_OK_V1';

  final CryptoService _cryptoService;
  final KeyValueStore _store;
  final LocalAuthentication _localAuth;
  final Future<bool> Function(String reason)? _biometricPromptOverride;

  bool _isDecoyMode = false;

  AuthService({
    required CryptoService cryptoService,
    KeyValueStore? store,
    LocalAuthentication? localAuth,
    Future<bool> Function(String reason)? biometricPromptOverride,
  })  : _cryptoService = cryptoService,
        _store = store ?? const FlutterSecureKeyValueStore(),
        _localAuth = localAuth ?? LocalAuthentication(),
        _biometricPromptOverride = biometricPromptOverride;

  bool get isUnlocked => _cryptoService.isUnlocked;
  bool get isDecoyMode => _isDecoyMode && _cryptoService.isUnlocked;

  void _zeroBytes(Uint8List? bytes) {
    if (bytes != null) {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<T> _withPreservedActiveSession<T>(Future<T> Function() action) async {
    final wasUnlocked = _cryptoService.isUnlocked;
    final wasDecoy = _isDecoyMode;
    Uint8List? savedDek;
    if (wasUnlocked) {
      savedDek = await _cryptoService.exportMasterKeyBytes();
    }
    try {
      return await action();
    } finally {
      _cryptoService.clearKey();
      _isDecoyMode = wasDecoy;
      if (savedDek != null) {
        _cryptoService.setActiveDek(savedDek);
        if (!wasDecoy) {
          await ensureX25519KeyPairLoaded();
        }
        _zeroBytes(savedDek);
      }
    }
  }

  Future<bool> isVaultSetup() async {
    final salt = await _store.read(_saltKey);
    final verifier = await _store.read(_verifierKey);
    return salt != null && verifier != null;
  }

  Future<bool> hasRecoveryKey() async {
    final rSalt = await _store.read(_recoverySaltKey);
    final rWrapped = await _store.read(_recoveryWrappedDekKey);
    return rSalt != null && rWrapped != null;
  }

  Future<bool> hasDecoyPassword() async {
    final salt = await _store.read(_decoySaltKey);
    final verifier = await _store.read(_decoyVerifierKey);
    final wrapped = await _store.read(_decoyWrappedDekKey);
    return salt != null && verifier != null && wrapped != null;
  }

  /// Returns the 32-byte X25519 Public Key (safe to read even when locked).
  Future<Uint8List?> getX25519PublicKeyBytes() async {
    final raw = await _store.read(_x25519PubKey);
    if (raw == null || raw.isEmpty) return null;
    return base64Decode(raw);
  }

  /// Ensures X25519 keypair exists and is loaded into CryptoService (master vault only).
  Future<void> ensureX25519KeyPairLoaded() async {
    if (!_cryptoService.isUnlocked || _isDecoyMode) return;

    Uint8List? dek;
    Uint8List? priv;
    try {
      dek = await _cryptoService.exportMasterKeyBytes();
      final pubB64 = await _store.read(_x25519PubKey);
      final wrappedPrivB64 = await _store.read(_x25519WrappedPrivKey);

      if (pubB64 != null && wrappedPrivB64 != null) {
        final pub = base64Decode(pubB64);
        priv = await _cryptoService.unwrapKey(
          wrappedKeyPayload: base64Decode(wrappedPrivB64),
          wrappingKeyBytes: dek,
        );
        _cryptoService.setX25519KeyPair(
          privateKeyBytes: priv,
          publicKeyBytes: pub,
        );
        return;
      }

      final generated = await _cryptoService.generateX25519KeyPair();
      priv = generated.privateKey;
      final wrappedPriv = await _cryptoService.wrapKey(
        keyToWrap: priv,
        wrappingKeyBytes: dek,
      );

      await _store.write(_x25519PubKey, base64Encode(generated.publicKey));
      await _store.write(_x25519WrappedPrivKey, base64Encode(wrappedPriv));
      _cryptoService.setX25519KeyPair(
        privateKeyBytes: priv,
        publicKeyBytes: generated.publicKey,
      );
    } finally {
      _zeroBytes(dek);
      _zeroBytes(priv);
    }
  }

  /// Exports Zero-Knowledge encrypted Key Bundle JSON (safe to store in Telegram).
  Future<String> exportCloudKeyBundleJson() async {
    if (!_cryptoService.isUnlocked || _isDecoyMode) {
      throw StateError('Unlock master vault before exporting cloud key bundle.');
    }
    await ensureX25519KeyPairLoaded();

    final salt = await _store.read(_saltKey);
    final verifier = await _store.read(_verifierKey);
    final wrappedDek = await _store.read(_wrappedDekKey);
    final recoverySalt = await _store.read(_recoverySaltKey);
    final recoveryWrappedDek = await _store.read(_recoveryWrappedDekKey);
    final x25519Pub = await _store.read(_x25519PubKey);
    final x25519WrappedPriv = await _store.read(_x25519WrappedPrivKey);

    if (salt == null || verifier == null || wrappedDek == null) {
      throw StateError('Vault keys are incomplete and cannot be exported.');
    }

    return jsonEncode({
      'schemaVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'salt': salt,
      'verifier': verifier,
      'wrappedDek': wrappedDek,
      'recoverySalt': recoverySalt,
      'recoveryWrappedDek': recoveryWrappedDek,
      'x25519Pub': x25519Pub,
      'x25519WrappedPriv': x25519WrappedPriv,
    });
  }

  /// Imports Zero-Knowledge Key Bundle JSON on a new device.
  Future<void> importCloudKeyBundleJson(String jsonString) async {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
      throw const FormatException('Invalid VAULT_KEY_BUNDLE_V1 format.');
    }

    final salt = decoded['salt'] as String?;
    final verifier = decoded['verifier'] as String?;
    final wrappedDek = decoded['wrappedDek'] as String?;
    if (salt == null || verifier == null || wrappedDek == null) {
      throw const FormatException('Cloud key bundle is missing required keys.');
    }

    await _store.write(_saltKey, salt);
    await _store.write(_verifierKey, verifier);
    await _store.write(_wrappedDekKey, wrappedDek);

    final rSalt = decoded['recoverySalt'] as String?;
    final rWrapped = decoded['recoveryWrappedDek'] as String?;
    if (rSalt != null && rWrapped != null) {
      await _store.write(_recoverySaltKey, rSalt);
      await _store.write(_recoveryWrappedDekKey, rWrapped);
    }

    final pub = decoded['x25519Pub'] as String?;
    final wPriv = decoded['x25519WrappedPriv'] as String?;
    if (pub != null && wPriv != null) {
      await _store.write(_x25519PubKey, pub);
      await _store.write(_x25519WrappedPrivKey, wPriv);
    }
  }

  Future<String> getOrCreateWipeCode() async {
    final existing = await _store.read(_remoteWipeCodeKey);
    if (existing != null && existing.isNotEmpty) return existing;

    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    String part(int len) =>
        List.generate(len, (_) => chars[rand.nextInt(chars.length)]).join();
    final code = 'WIPE-${part(4)}-${part(4)}';
    await _store.write(_remoteWipeCodeKey, code);
    return code;
  }

  Future<String> setupMasterPassword(String password) async {
    if (password.isEmpty) {
      throw ArgumentError('Password cannot be empty');
    }

    Uint8List? kekBytes;
    Uint8List? dek;
    Uint8List? recoveryWrappingKey;

    try {
      _cryptoService.clearKey();
      _isDecoyMode = false;

      final salt = _cryptoService.generateSalt(16);
      await _cryptoService.deriveKey(password, salt);
      kekBytes = await _cryptoService.exportMasterKeyBytes();

      dek = _cryptoService.generateDek();
      final wrappedDek = await _cryptoService.wrapKey(
        keyToWrap: dek,
        wrappingKeyBytes: kekBytes,
      );

      final recoveryKey = _cryptoService.generateRecoveryKey();
      final recoverySalt = _cryptoService.generateSalt(16);
      recoveryWrappingKey = await _cryptoService.deriveRecoveryWrappingKey(
        recoveryKey,
        recoverySalt,
      );
      final recoveryWrappedDek = await _cryptoService.wrapKey(
        keyToWrap: dek,
        wrappingKeyBytes: recoveryWrappingKey,
      );

      _cryptoService.clearKey();
      _cryptoService.setActiveDek(dek);

      final canaryBytes = Uint8List.fromList(utf8.encode(_canaryPlaintext));
      final encryptedCanary = await _cryptoService.encrypt(canaryBytes);

      await _store.write(_saltKey, base64Encode(salt));
      await _store.write(_verifierKey, base64Encode(encryptedCanary));
      await _store.write(_wrappedDekKey, base64Encode(wrappedDek));
      await _store.write(_recoverySaltKey, base64Encode(recoverySalt));
      await _store.write(
        _recoveryWrappedDekKey,
        base64Encode(recoveryWrappedDek),
      );
      await getOrCreateWipeCode();
      await ensureX25519KeyPairLoaded();

      return recoveryKey;
    } finally {
      _zeroBytes(kekBytes);
      _zeroBytes(dek);
      _zeroBytes(recoveryWrappingKey);
    }
  }

  Future<bool> _tryUnlockMasterInternal(String password) async {
    final saltBase64 = await _store.read(_saltKey);
    final verifierBase64 = await _store.read(_verifierKey);
    if (saltBase64 == null || verifierBase64 == null) {
      return false;
    }

    final wrappedDekBase64 = await _store.read(_wrappedDekKey);
    final salt = base64Decode(saltBase64);
    final encryptedCanary = base64Decode(verifierBase64);

    if (wrappedDekBase64 != null) {
      Uint8List? kekBytes;
      Uint8List? dek;
      try {
        _cryptoService.clearKey();
        await _cryptoService.deriveKey(password, salt);
        kekBytes = await _cryptoService.exportMasterKeyBytes();

        dek = await _cryptoService.unwrapKey(
          wrappedKeyPayload: base64Decode(wrappedDekBase64),
          wrappingKeyBytes: kekBytes,
        );

        _cryptoService.clearKey();
        _cryptoService.setActiveDek(dek);

        final decryptedBytes = await _cryptoService.decrypt(encryptedCanary);
        final decryptedText = utf8.decode(decryptedBytes);
        if (decryptedText == _canaryPlaintext) {
          _isDecoyMode = false;
          await ensureX25519KeyPairLoaded();
          return true;
        }

        _cryptoService.clearKey();
        return false;
      } catch (_) {
        _cryptoService.clearKey();
        return false;
      } finally {
        _zeroBytes(kekBytes);
        _zeroBytes(dek);
      }
    }

    // Legacy v1 vault support
    try {
      _cryptoService.clearKey();
      await _cryptoService.deriveKey(password, salt);
      final decryptedBytes = await _cryptoService.decrypt(encryptedCanary);
      final decryptedText = utf8.decode(decryptedBytes);

      if (decryptedText == _canaryPlaintext) {
        _isDecoyMode = false;
        await ensureX25519KeyPairLoaded();
        return true;
      }

      _cryptoService.clearKey();
      return false;
    } catch (_) {
      _cryptoService.clearKey();
      return false;
    }
  }

  Future<bool> _tryUnlockDecoyInternal(String password) async {
    final saltBase64 = await _store.read(_decoySaltKey);
    final verifierBase64 = await _store.read(_decoyVerifierKey);
    final wrappedDekBase64 = await _store.read(_decoyWrappedDekKey);
    if (saltBase64 == null ||
        verifierBase64 == null ||
        wrappedDekBase64 == null) {
      return false;
    }

    Uint8List? kekBytes;
    Uint8List? decoyDek;
    try {
      _cryptoService.clearKey();
      await _cryptoService.deriveKey(password, base64Decode(saltBase64));
      kekBytes = await _cryptoService.exportMasterKeyBytes();

      decoyDek = await _cryptoService.unwrapKey(
        wrappedKeyPayload: base64Decode(wrappedDekBase64),
        wrappingKeyBytes: kekBytes,
      );

      _cryptoService.clearKey();
      _cryptoService.setActiveDek(decoyDek);

      final decryptedBytes =
          await _cryptoService.decrypt(base64Decode(verifierBase64));
      if (utf8.decode(decryptedBytes) == _decoyCanaryPlaintext) {
        _isDecoyMode = true;
        return true;
      }

      _cryptoService.clearKey();
      _isDecoyMode = false;
      return false;
    } catch (_) {
      _cryptoService.clearKey();
      _isDecoyMode = false;
      return false;
    } finally {
      _zeroBytes(kekBytes);
      _zeroBytes(decoyDek);
    }
  }

  Future<bool> _matchesMasterPassword(String candidate) {
    return _withPreservedActiveSession(() => _tryUnlockMasterInternal(candidate));
  }

  Future<bool> _matchesDecoyPassword(String candidate) async {
    if (!await hasDecoyPassword()) return false;
    return _withPreservedActiveSession(() => _tryUnlockDecoyInternal(candidate));
  }

  /// Unlocks either the real Master Vault or the isolated Decoy Vault silently.
  Future<UnlockMode> unlockWithPasswordMode(String password) async {
    if (password.isEmpty) return UnlockMode.none;

    if (await _tryUnlockMasterInternal(password)) {
      return UnlockMode.master;
    }
    if (await _tryUnlockDecoyInternal(password)) {
      return UnlockMode.decoy;
    }
    _cryptoService.clearKey();
    _isDecoyMode = false;
    return UnlockMode.none;
  }

  Future<bool> unlockWithPassword(String password) async {
    final mode = await unlockWithPasswordMode(password);
    return mode != UnlockMode.none;
  }

  /// Sets or replaces the isolated Decoy PIN/password (Master vault must be unlocked).
  Future<void> setupDecoyPassword(String decoyPassword) async {
    if (!_cryptoService.isUnlocked || _isDecoyMode) {
      throw StateError('Unlock the master vault before configuring a Decoy PIN.');
    }
    if (decoyPassword.length < 4) {
      throw ArgumentError('Decoy PIN/password must be at least 4 characters.');
    }
    if (await _matchesMasterPassword(decoyPassword)) {
      throw ArgumentError(
        'Decoy PIN/password must be different from your master password.',
      );
    }

    await _withPreservedActiveSession(() async {
      Uint8List? decoyKek;
      Uint8List? decoyDek;
      try {
        final decoySalt = _cryptoService.generateSalt(16);
        _cryptoService.clearKey();
        await _cryptoService.deriveKey(decoyPassword, decoySalt);
        decoyKek = await _cryptoService.exportMasterKeyBytes();

        decoyDek = _cryptoService.generateDek();
        final wrappedDecoyDek = await _cryptoService.wrapKey(
          keyToWrap: decoyDek,
          wrappingKeyBytes: decoyKek,
        );

        _cryptoService.clearKey();
        _cryptoService.setActiveDek(decoyDek);

        final canaryBytes =
            Uint8List.fromList(utf8.encode(_decoyCanaryPlaintext));
        final encryptedCanary = await _cryptoService.encrypt(canaryBytes);

        await _store.write(_decoySaltKey, base64Encode(decoySalt));
        await _store.write(_decoyVerifierKey, base64Encode(encryptedCanary));
        await _store.write(_decoyWrappedDekKey, base64Encode(wrappedDecoyDek));
      } finally {
        _zeroBytes(decoyKek);
        _zeroBytes(decoyDek);
      }
    });
  }

  Future<void> removeDecoyPassword() async {
    if (_isDecoyMode) {
      throw StateError('Cannot modify decoy configuration in decoy mode.');
    }
    await _store.delete(_decoySaltKey);
    await _store.delete(_decoyVerifierKey);
    await _store.delete(_decoyWrappedDekKey);
  }

  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (_isDecoyMode) return false;
    if (currentPassword.isEmpty || newPassword.length < 8) {
      return false;
    }
    if (await _matchesDecoyPassword(newPassword)) {
      return false;
    }

    final saltBase64 = await _store.read(_saltKey);
    final verifierBase64 = await _store.read(_verifierKey);
    if (saltBase64 == null || verifierBase64 == null) {
      return false;
    }

    final wrappedDekBase64 = await _store.read(_wrappedDekKey);
    final oldSalt = base64Decode(saltBase64);

    if (wrappedDekBase64 != null) {
      try {
        final newSalt = _cryptoService.generateSalt(16);
        final newWrappedDek = await _cryptoService.rewrapDekForNewPassword(
          wrappedDekPayload: base64Decode(wrappedDekBase64),
          oldPassword: currentPassword,
          oldSalt: oldSalt,
          newPassword: newPassword,
          newSalt: newSalt,
        );

        await _store.write(_saltKey, base64Encode(newSalt));
        await _store.write(_wrappedDekKey, base64Encode(newWrappedDek));
        return true;
      } catch (_) {
        return false;
      }
    }

    // Legacy v1 upgrade to v2 DEK/KEK
    Uint8List? existingKeyBackup;
    Uint8List? oldMasterAsDek;
    Uint8List? newKek;
    try {
      if (_cryptoService.isUnlocked) {
        existingKeyBackup = await _cryptoService.exportMasterKeyBytes();
      }

      _cryptoService.clearKey();
      await _cryptoService.deriveKey(currentPassword, oldSalt);
      final decryptedBytes =
          await _cryptoService.decrypt(base64Decode(verifierBase64));
      if (utf8.decode(decryptedBytes) != _canaryPlaintext) {
        _cryptoService.clearKey();
        if (existingKeyBackup != null) {
          _cryptoService.setActiveDek(existingKeyBackup);
        }
        return false;
      }

      oldMasterAsDek = await _cryptoService.exportMasterKeyBytes();
      final newSalt = _cryptoService.generateSalt(16);
      _cryptoService.clearKey();
      await _cryptoService.deriveKey(newPassword, newSalt);
      newKek = await _cryptoService.exportMasterKeyBytes();

      final wrappedDek = await _cryptoService.wrapKey(
        keyToWrap: oldMasterAsDek,
        wrappingKeyBytes: newKek,
      );

      _cryptoService.clearKey();
      _cryptoService.setActiveDek(oldMasterAsDek);
      await ensureX25519KeyPairLoaded();

      await _store.write(_saltKey, base64Encode(newSalt));
      await _store.write(_wrappedDekKey, base64Encode(wrappedDek));
      return true;
    } catch (_) {
      _cryptoService.clearKey();
      if (existingKeyBackup != null) {
        _cryptoService.setActiveDek(existingKeyBackup);
      }
      return false;
    } finally {
      _zeroBytes(existingKeyBackup);
      _zeroBytes(oldMasterAsDek);
      _zeroBytes(newKek);
    }
  }

  Future<bool> recoverWithRecoveryKey({
    required String recoveryKey,
    required String newPassword,
  }) async {
    if (recoveryKey.trim().isEmpty || newPassword.length < 8) {
      return false;
    }

    final recoverySaltBase64 = await _store.read(_recoverySaltKey);
    final recoveryWrappedBase64 = await _store.read(_recoveryWrappedDekKey);
    final verifierBase64 = await _store.read(_verifierKey);
    if (recoverySaltBase64 == null ||
        recoveryWrappedBase64 == null ||
        verifierBase64 == null) {
      return false;
    }

    Uint8List? recoveryWrappingKey;
    Uint8List? dek;
    Uint8List? newKek;

    try {
      recoveryWrappingKey = await _cryptoService.deriveRecoveryWrappingKey(
        recoveryKey,
        base64Decode(recoverySaltBase64),
      );
      dek = await _cryptoService.unwrapKey(
        wrappedKeyPayload: base64Decode(recoveryWrappedBase64),
        wrappingKeyBytes: recoveryWrappingKey,
      );

      _cryptoService.clearKey();
      _isDecoyMode = false;
      _cryptoService.setActiveDek(dek);
      final decryptedBytes =
          await _cryptoService.decrypt(base64Decode(verifierBase64));
      if (utf8.decode(decryptedBytes) != _canaryPlaintext) {
        _cryptoService.clearKey();
        return false;
      }

      final newSalt = _cryptoService.generateSalt(16);
      _cryptoService.clearKey();
      await _cryptoService.deriveKey(newPassword, newSalt);
      newKek = await _cryptoService.exportMasterKeyBytes();

      final newWrappedDek = await _cryptoService.wrapKey(
        keyToWrap: dek,
        wrappingKeyBytes: newKek,
      );

      _cryptoService.clearKey();
      _isDecoyMode = false;
      _cryptoService.setActiveDek(dek);
      await ensureX25519KeyPairLoaded();

      await _store.write(_saltKey, base64Encode(newSalt));
      await _store.write(_wrappedDekKey, base64Encode(newWrappedDek));

      if (await isBiometricEnabled()) {
        await _store.write(_biometricMasterKey, base64Encode(dek));
      }

      return true;
    } catch (_) {
      _cryptoService.clearKey();
      return false;
    } finally {
      _zeroBytes(recoveryWrappingKey);
      _zeroBytes(dek);
      _zeroBytes(newKek);
    }
  }

  Future<String> regenerateRecoveryKey() async {
    if (!_cryptoService.isUnlocked || _isDecoyMode) {
      throw StateError('Unlock the master vault before generating a recovery key');
    }

    Uint8List? dek;
    Uint8List? recoveryWrappingKey;
    try {
      dek = await _cryptoService.exportMasterKeyBytes();
      final recoveryKey = _cryptoService.generateRecoveryKey();
      final recoverySalt = _cryptoService.generateSalt(16);
      recoveryWrappingKey = await _cryptoService.deriveRecoveryWrappingKey(
        recoveryKey,
        recoverySalt,
      );
      final recoveryWrappedDek = await _cryptoService.wrapKey(
        keyToWrap: dek,
        wrappingKeyBytes: recoveryWrappingKey,
      );

      await _store.write(_recoverySaltKey, base64Encode(recoverySalt));
      await _store.write(
        _recoveryWrappedDekKey,
        base64Encode(recoveryWrappedDek),
      );
      return recoveryKey;
    } finally {
      _zeroBytes(dek);
      _zeroBytes(recoveryWrappingKey);
    }
  }

  Future<bool> isBiometricAvailable() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isBiometricEnabled() async {
    final flag = await _store.read(_biometricEnabledKey);
    final savedKey = await _store.read(_biometricMasterKey);
    return flag == 'true' && savedKey != null;
  }

  Future<void> enableBiometricUnlock() async {
    if (!_cryptoService.isUnlocked || _isDecoyMode) {
      throw StateError('Unlock the master vault before enabling biometrics');
    }
    final masterKeyBytes = await _cryptoService.exportMasterKeyBytes();
    try {
      await _store.write(_biometricMasterKey, base64Encode(masterKeyBytes));
      await _store.write(_biometricEnabledKey, 'true');
    } finally {
      _zeroBytes(masterKeyBytes);
    }
  }

  Future<void> disableBiometricUnlock() async {
    if (_isDecoyMode) return;
    await _store.delete(_biometricMasterKey);
    await _store.write(_biometricEnabledKey, 'false');
  }

  Future<bool> unlockWithBiometrics({
    String reason = 'Verify to unlock Vault',
  }) async {
    if (!await isBiometricEnabled()) {
      return false;
    }

    final savedKeyBase64 = await _store.read(_biometricMasterKey);
    if (savedKeyBase64 == null) {
      return false;
    }

    Uint8List? keyBytes;
    try {
      final override = _biometricPromptOverride;
      final authenticated = override != null
          ? await override(reason)
          : await _localAuth.authenticate(localizedReason: reason);

      if (!authenticated) {
        return false;
      }

      keyBytes = base64Decode(savedKeyBase64);
      _isDecoyMode = false;
      _cryptoService.setActiveDek(keyBytes);
      await ensureX25519KeyPairLoaded();
      return true;
    } catch (_) {
      _cryptoService.clearKey();
      _isDecoyMode = false;
      return false;
    } finally {
      _zeroBytes(keyBytes);
    }
  }

  void lock() {
    _isDecoyMode = false;
    _cryptoService.clearKey();
  }

  Future<void> wipeAuthData() async {
    _isDecoyMode = false;
    _cryptoService.clearKey();
    await _store.delete(_saltKey);
    await _store.delete(_verifierKey);
    await _store.delete(_wrappedDekKey);
    await _store.delete(_recoverySaltKey);
    await _store.delete(_recoveryWrappedDekKey);
    await _store.delete(_remoteWipeCodeKey);
    await _store.delete(_biometricEnabledKey);
    await _store.delete(_biometricMasterKey);
    await _store.delete(_x25519PubKey);
    await _store.delete(_x25519WrappedPrivKey);
    await _store.delete(_decoySaltKey);
    await _store.delete(_decoyVerifierKey);
    await _store.delete(_decoyWrappedDekKey);
  }
}