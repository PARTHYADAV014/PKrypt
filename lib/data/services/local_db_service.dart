import 'dart:typed_data';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/face_cluster.dart';
import '../models/vault_channel.dart';
import '../models/vault_media.dart';

class LocalDbService {
  static const String _mediaBoxName = 'vault_media_v1';
  static const String _channelBoxName = 'vault_channels_v1';
  static const String _faceBoxName = 'vault_faces_v1';

  static const String _decoyMediaBoxName = 'vault_decoy_media_v1';
  static const String _decoyChannelBoxName = 'vault_decoy_channels_v1';
  static const String _decoyFaceBoxName = 'vault_decoy_faces_v1';

  Box? _mediaBox;
  Box? _channelBox;
  Box? _faceBox;
  bool _initialized = false;
  bool _isDecoyOpen = false;

  bool get isOpen =>
      (_mediaBox?.isOpen ?? false) &&
      (_channelBox?.isOpen ?? false) &&
      (_faceBox?.isOpen ?? false);

  bool get isDecoyOpen => _isDecoyOpen && isOpen;

  Future<void> init({String? customPath}) async {
    if (customPath != null) {
      Hive.init(customPath);
      _initialized = true;
      return;
    }
    if (!_initialized) {
      await Hive.initFlutter();
      _initialized = true;
    }
  }

  Future<void> open(Uint8List masterKeyBytes, {bool decoy = false}) async {
    if (masterKeyBytes.length != 32) {
      throw ArgumentError('Hive encryption key must be 32 bytes');
    }

    if (isOpen) {
      await close();
    }

    final cipher = HiveAesCipher(masterKeyBytes);
    _mediaBox = await Hive.openBox(
      decoy ? _decoyMediaBoxName : _mediaBoxName,
      encryptionCipher: cipher,
      crashRecovery: false,
    );
    _channelBox = await Hive.openBox(
      decoy ? _decoyChannelBoxName : _channelBoxName,
      encryptionCipher: cipher,
      crashRecovery: false,
    );
    _faceBox = await Hive.openBox(
      decoy ? _decoyFaceBoxName : _faceBoxName,
      encryptionCipher: cipher,
      crashRecovery: false,
    );
    _isDecoyOpen = decoy;
  }

  void _ensureOpen() {
    if (!isOpen) {
      throw StateError(
        'Database is closed. Unlock the vault and call open() first.',
      );
    }
  }

  // ---------------- MEDIA OPERATIONS ----------------

  Future<void> saveMedia(VaultMedia item) async {
    _ensureOpen();
    await _mediaBox!.put(item.id, item.toMap());
  }

  VaultMedia? getMedia(String id) {
    _ensureOpen();
    final raw = _mediaBox!.get(id);
    if (raw == null) return null;
    return VaultMedia.fromMap(raw);
  }

  VaultMedia? findMediaByHash(String contentHash) {
    _ensureOpen();
    if (contentHash.isEmpty) return null;
    for (final raw in _mediaBox!.values) {
      final item = VaultMedia.fromMap(raw);
      if (item.contentHash == contentHash && item.uploadStatus == 'uploaded') {
        return item;
      }
    }
    return null;
  }

  Set<String> getAllContentHashes() {
    _ensureOpen();
    final hashes = <String>{};
    for (final raw in _mediaBox!.values) {
      final item = VaultMedia.fromMap(raw);
      final h = item.contentHash;
      if (h != null && h.isNotEmpty && item.uploadStatus == 'uploaded') {
        hashes.add(h);
      }
    }
    return hashes;
  }

  List<VaultMedia> getAllMedia({
    String? album,
    bool onlyFavorites = false,
  }) {
    _ensureOpen();
    final items = _mediaBox!.values
        .map((raw) => VaultMedia.fromMap(raw))
        .where((item) {
          if (album != null && album != 'All' && item.album != album) {
            return false;
          }
          if (onlyFavorites && !item.isFavorite) {
            return false;
          }
          return true;
        })
        .toList();

    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  List<VaultMedia> getMediaForFaceCluster(String clusterId) {
    _ensureOpen();
    final items = _mediaBox!.values
        .map((raw) => VaultMedia.fromMap(raw))
        .where((item) => item.faceClusterIds.contains(clusterId))
        .toList();
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  List<VaultMedia> getPendingUploads() {
    _ensureOpen();
    return _mediaBox!.values
        .map((raw) => VaultMedia.fromMap(raw))
        .where((item) =>
            item.uploadStatus == 'pending' || item.uploadStatus == 'failed')
        .toList();
  }

  Future<void> deleteMedia(String id) async {
    _ensureOpen();
    await _mediaBox!.delete(id);
  }

  // ---------------- CHANNEL OPERATIONS ----------------

  Future<void> saveChannel(VaultChannel channel) async {
    _ensureOpen();
    await _channelBox!.put(channel.chatId.toString(), channel.toMap());
  }

  List<VaultChannel> getAllChannels() {
    _ensureOpen();
    return _channelBox!.values
        .map((raw) => VaultChannel.fromMap(raw))
        .toList();
  }

  VaultChannel? getPrimaryChannel() {
    for (final ch in getAllChannels()) {
      if (ch.isPrimary) return ch;
    }
    return null;
  }

  VaultChannel? getBackupChannel() {
    for (final ch in getAllChannels()) {
      if (ch.isBackup) return ch;
    }
    return null;
  }

  Future<void> deleteChannel(int chatId) async {
    _ensureOpen();
    await _channelBox!.delete(chatId.toString());
  }

  // ---------------- FACE CLUSTERS (PEOPLE) ----------------

  Future<void> saveFaceCluster(FaceCluster cluster) async {
    _ensureOpen();
    await _faceBox!.put(cluster.id, cluster.toMap());
  }

  FaceCluster? getFaceCluster(String id) {
    _ensureOpen();
    final raw = _faceBox!.get(id);
    if (raw == null) return null;
    return FaceCluster.fromMap(raw);
  }

  List<FaceCluster> getAllFaceClusters() {
    _ensureOpen();
    final clusters = _faceBox!.values
        .map((raw) => FaceCluster.fromMap(raw))
        .toList();
    clusters.sort((a, b) => b.sampleCount.compareTo(a.sampleCount));
    return clusters;
  }

  Future<void> deleteFaceCluster(String id) async {
    _ensureOpen();
    await _faceBox!.delete(id);
  }

  Future<void> clearAllFaceClusters() async {
    _ensureOpen();
    await _faceBox!.clear();
  }

  // ---------------- LOCK & WIPE ----------------

  Future<void> close() async {
    if (_mediaBox?.isOpen ?? false) {
      await _mediaBox!.close();
    }
    if (_channelBox?.isOpen ?? false) {
      await _channelBox!.close();
    }
    if (_faceBox?.isOpen ?? false) {
      await _faceBox!.close();
    }
    _mediaBox = null;
    _channelBox = null;
    _faceBox = null;
    _isDecoyOpen = false;
  }

  /// Safely wipes ONLY decoy Hive boxes while leaving the real master DB untouched.
  Future<void> wipeDecoyBoxes() async {
    if (_isDecoyOpen) {
      await close();
    }
    await Hive.deleteBoxFromDisk(_decoyMediaBoxName);
    await Hive.deleteBoxFromDisk(_decoyChannelBoxName);
    await Hive.deleteBoxFromDisk(_decoyFaceBoxName);
  }

  Future<void> wipeAll() async {
    await close();
    await Hive.deleteBoxFromDisk(_mediaBoxName);
    await Hive.deleteBoxFromDisk(_channelBoxName);
    await Hive.deleteBoxFromDisk(_faceBoxName);
    await Hive.deleteBoxFromDisk(_decoyMediaBoxName);
    await Hive.deleteBoxFromDisk(_decoyChannelBoxName);
    await Hive.deleteBoxFromDisk(_decoyFaceBoxName);
  }
}