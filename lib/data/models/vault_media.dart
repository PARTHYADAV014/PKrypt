class VaultMedia {
  final String id;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final DateTime createdAt;
  final String album;
  final bool isFavorite;
  final String uploadStatus; // 'pending', 'uploading', 'uploaded', 'failed'
  final int? primaryChatId;
  final List<int> chunkMessageIds;
  final int? backupChatId;
  final List<int> backupMessageIds;
  final String? localEncryptedPath;
  final String? localThumbPath;
  final List<String> faceClusterIds;
  final String? contentHash;
  final bool isPerChunkEncrypted;
  final bool facesScanned;

  const VaultMedia({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
    this.album = 'All',
    this.isFavorite = false,
    this.uploadStatus = 'pending',
    this.primaryChatId,
    this.chunkMessageIds = const [],
    this.backupChatId,
    this.backupMessageIds = const [],
    this.localEncryptedPath,
    this.localThumbPath,
    this.faceClusterIds = const [],
    this.contentHash,
    this.isPerChunkEncrypted = false,
    this.facesScanned = false,
  });

  VaultMedia copyWith({
    String? fileName,
    String? mimeType,
    int? sizeBytes,
    DateTime? createdAt,
    String? album,
    bool? isFavorite,
    String? uploadStatus,
    int? primaryChatId,
    List<int>? chunkMessageIds,
    int? backupChatId,
    List<int>? backupMessageIds,
    String? localEncryptedPath,
    String? localThumbPath,
    List<String>? faceClusterIds,
    String? contentHash,
    bool? isPerChunkEncrypted,
    bool? facesScanned,
  }) {
    return VaultMedia(
      id: id,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt ?? this.createdAt,
      album: album ?? this.album,
      isFavorite: isFavorite ?? this.isFavorite,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      primaryChatId: primaryChatId ?? this.primaryChatId,
      chunkMessageIds: chunkMessageIds ?? this.chunkMessageIds,
      backupChatId: backupChatId ?? this.backupChatId,
      backupMessageIds: backupMessageIds ?? this.backupMessageIds,
      localEncryptedPath: localEncryptedPath ?? this.localEncryptedPath,
      localThumbPath: localThumbPath ?? this.localThumbPath,
      faceClusterIds: faceClusterIds ?? this.faceClusterIds,
      contentHash: contentHash ?? this.contentHash,
      isPerChunkEncrypted: isPerChunkEncrypted ?? this.isPerChunkEncrypted,
      facesScanned: facesScanned ?? this.facesScanned,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'album': album,
      'isFavorite': isFavorite,
      'uploadStatus': uploadStatus,
      'primaryChatId': primaryChatId,
      'chunkMessageIds': chunkMessageIds,
      'backupChatId': backupChatId,
      'backupMessageIds': backupMessageIds,
      'localEncryptedPath': localEncryptedPath,
      'localThumbPath': localThumbPath,
      'faceClusterIds': faceClusterIds,
      'contentHash': contentHash,
      'isPerChunkEncrypted': isPerChunkEncrypted,
      'facesScanned': facesScanned,
    };
  }

  factory VaultMedia.fromMap(Map<dynamic, dynamic> map) {
    return VaultMedia(
      id: map['id'] as String,
      fileName: map['fileName'] as String,
      mimeType: map['mimeType'] as String,
      sizeBytes: map['sizeBytes'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      album: (map['album'] as String?) ?? 'All',
      isFavorite: (map['isFavorite'] as bool?) ?? false,
      uploadStatus: (map['uploadStatus'] as String?) ?? 'pending',
      primaryChatId: map['primaryChatId'] as int?,
      chunkMessageIds: (map['chunkMessageIds'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      backupChatId: map['backupChatId'] as int?,
      backupMessageIds: (map['backupMessageIds'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      localEncryptedPath: map['localEncryptedPath'] as String?,
      localThumbPath: map['localThumbPath'] as String?,
      faceClusterIds: (map['faceClusterIds'] as List?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      contentHash: map['contentHash'] as String?,
      isPerChunkEncrypted: (map['isPerChunkEncrypted'] as bool?) ?? false,
      facesScanned: (map['facesScanned'] as bool?) ?? false,
    );
  }
}