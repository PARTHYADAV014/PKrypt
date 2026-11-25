import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:vault_gallery/data/models/vault_channel.dart';
import 'package:vault_gallery/data/models/vault_media.dart';
import 'package:vault_gallery/data/services/crypto_service.dart';
import 'package:vault_gallery/data/services/local_db_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_hive_test_');
  });

  tearDown(() async {
    await Hive.close();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('Save, read, update, and filter VaultMedia & VaultChannel', () async {
    final crypto = CryptoService();
    final salt = crypto.generateSalt();
    await crypto.deriveKey('VaultPass@123', salt);
    final keyBytes = await crypto.exportMasterKeyBytes();

    final db = LocalDbService();
    await db.init(customPath: tempDir.path);
    await db.open(keyBytes);

    // 1. Photo metadata save karo
    final photo = VaultMedia(
      id: 'img_001',
      fileName: 'IMG_20261120.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 2450000,
      createdAt: DateTime(2026, 11, 20, 12, 0),
      album: 'Camera',
    );
    await db.saveMedia(photo);

    expect(db.getMedia('img_001')?.fileName, 'IMG_20261120.jpg');
    expect(db.getPendingUploads().length, 1);

    // 2. Upload hone ke baad Telegram IDs update karo
    final uploadedPhoto = photo.copyWith(
      uploadStatus: 'uploaded',
      primaryChatId: -1001987654321,
      chunkMessageIds: [42, 43],
      isFavorite: true,
    );
    await db.saveMedia(uploadedPhoto);

    expect(db.getPendingUploads(), isEmpty);
    expect(db.getAllMedia(onlyFavorites: true).length, 1);
    expect(db.getMedia('img_001')?.chunkMessageIds, [42, 43]);

    // 3. Telegram Primary & Backup channel save karo
    await db.saveChannel(VaultChannel(
      chatId: -1001987654321,
      title: 'Vault Main',
      isPrimary: true,
      addedAt: DateTime.now(),
    ));
    await db.saveChannel(VaultChannel(
      chatId: -1001112223334,
      title: 'Vault Backup',
      isBackup: true,
      addedAt: DateTime.now(),
    ));

    expect(db.getPrimaryChannel()?.title, 'Vault Main');
    expect(db.getBackupChannel()?.title, 'Vault Backup');

    await db.close();
  });

  test('Hive database file on disk is actually encrypted (no plaintext)', () async {
    final rightKey = Uint8List.fromList(List.generate(32, (i) => i + 1));

    final db = LocalDbService();
    await db.init(customPath: tempDir.path);
    await db.open(rightKey);
    await db.saveMedia(VaultMedia(
      id: 'secret_1',
      fileName: 'super_secret_photo_999.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 1024,
      createdAt: DateTime.now(),
    ));
    await db.close();

    // Disk par save hui .hive file ko raw read karo — plaintext naam nahi milna chahiye
    final hiveFiles = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.hive'))
        .toList();
    expect(hiveFiles, isNotEmpty);

    for (final file in hiveFiles) {
      final rawText = latin1.decode(await file.readAsBytes(), allowInvalid: true);
      expect(rawText.contains('super_secret_photo_999.jpg'), isFalse);
    }

    // Sahi key se dobara kholne par data wapas milna chahiye
    await db.open(rightKey);
    expect(db.getMedia('secret_1')?.fileName, 'super_secret_photo_999.jpg');
    await db.close();
  });

  test('wipeAll deletes all saved metadata from disk', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i + 5));
    final db = LocalDbService();
    await db.init(customPath: tempDir.path);
    await db.open(key);
    await db.saveMedia(VaultMedia(
      id: 'wipe_1',
      fileName: 'temp.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 500,
      createdAt: DateTime.now(),
    ));
    expect(db.getAllMedia().length, 1);

    await db.wipeAll();

    await db.open(key);
    expect(db.getAllMedia(), isEmpty);
    await db.close();
  });
}