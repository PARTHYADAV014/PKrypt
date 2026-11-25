class VaultChannel {
  final int chatId;
  final String title;
  final bool isPrimary;
  final bool isBackup;
  final DateTime addedAt;

  const VaultChannel({
    required this.chatId,
    required this.title,
    this.isPrimary = false,
    this.isBackup = false,
    required this.addedAt,
  });

  VaultChannel copyWith({
    String? title,
    bool? isPrimary,
    bool? isBackup,
  }) {
    return VaultChannel(
      chatId: chatId,
      title: title ?? this.title,
      isPrimary: isPrimary ?? this.isPrimary,
      isBackup: isBackup ?? this.isBackup,
      addedAt: addedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'chatId': chatId,
      'title': title,
      'isPrimary': isPrimary,
      'isBackup': isBackup,
      'addedAt': addedAt.millisecondsSinceEpoch,
    };
  }

  factory VaultChannel.fromMap(Map<dynamic, dynamic> map) {
    return VaultChannel(
      chatId: map['chatId'] as int,
      title: map['title'] as String,
      isPrimary: (map['isPrimary'] as bool?) ?? false,
      isBackup: (map['isBackup'] as bool?) ?? false,
      addedAt: DateTime.fromMillisecondsSinceEpoch(map['addedAt'] as int),
    );
  }
}