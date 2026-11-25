import 'package:flutter_test/flutter_test.dart';
import 'package:vault_gallery/data/services/auth_service.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

void main() {
  test('Password setup, wrong password reject, and right password unlock', () async {
    final crypto = CryptoService();
    final store = _InMemoryStore();
    final auth = AuthService(cryptoService: crypto, store: store);

    expect(await auth.isVaultSetup(), isFalse);

    await auth.setupMasterPassword('SuperSecret@123');
    expect(await auth.isVaultSetup(), isTrue);
    expect(auth.isUnlocked, isTrue);

    auth.lock();
    expect(auth.isUnlocked, isFalse);

    final wrongLogin = await auth.unlockWithPassword('GalatPassword');
    expect(wrongLogin, isFalse);
    expect(auth.isUnlocked, isFalse);

    final rightLogin = await auth.unlockWithPassword('SuperSecret@123');
    expect(rightLogin, isTrue);
    expect(auth.isUnlocked, isTrue);
  });

  test('Biometric enable, unlock, and disable flow', () async {
    final crypto = CryptoService();
    final store = _InMemoryStore();
    final auth = AuthService(
      cryptoService: crypto,
      store: store,
      biometricPromptOverride: (_) async => true,
    );

    await auth.setupMasterPassword('MyVaultPass#99');
    await auth.enableBiometricUnlock();
    expect(await auth.isBiometricEnabled(), isTrue);

    auth.lock();
    expect(auth.isUnlocked, isFalse);

    final bioUnlock = await auth.unlockWithBiometrics();
    expect(bioUnlock, isTrue);
    expect(auth.isUnlocked, isTrue);

    await auth.disableBiometricUnlock();
    expect(await auth.isBiometricEnabled(), isFalse);
  });
}