class FaceCluster {
  final String id;
  final String name;
  final List<double> embedding;
  final int sampleCount;
  final String? avatarPath;
  final DateTime createdAt;

  const FaceCluster({
    required this.id,
    required this.name,
    required this.embedding,
    this.sampleCount = 1,
    this.avatarPath,
    required this.createdAt,
  });

  FaceCluster copyWith({
    String? name,
    List<double>? embedding,
    int? sampleCount,
    String? avatarPath,
    DateTime? createdAt,
  }) {
    return FaceCluster(
      id: id,
      name: name ?? this.name,
      embedding: embedding ?? this.embedding,
      sampleCount: sampleCount ?? this.sampleCount,
      avatarPath: avatarPath ?? this.avatarPath,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'embedding': embedding,
      'sampleCount': sampleCount,
      'avatarPath': avatarPath,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  factory FaceCluster.fromMap(Map<dynamic, dynamic> map) {
    return FaceCluster(
      id: map['id'] as String,
      name: (map['name'] as String?) ?? 'Person',
      embedding: ((map['embedding'] as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(),
      sampleCount: (map['sampleCount'] as num?)?.toInt() ?? 1,
      avatarPath: map['avatarPath'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}