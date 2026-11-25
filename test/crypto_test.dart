import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_gallery/data/services/crypto_service.dart'; 

void main() {
  test('Encryption and Decryption Test', () async {
    final crypto = CryptoService();
    
    // Dummy password aur salt
    final salt = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
    await crypto.deriveKey('MySuperSecretPassword123!', salt);

    // Original data
    final originalData = Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80]);

    // Encrypt
    final encryptedData = await crypto.encrypt(originalData);
    
    // Check ki data encrypt hua
    expect(encryptedData, isNot(equals(originalData)));

    // Decrypt
    final decryptedData = await crypto.decrypt(encryptedData);

    // Check ki wapas same mila
    expect(decryptedData, equals(originalData));
  });
}