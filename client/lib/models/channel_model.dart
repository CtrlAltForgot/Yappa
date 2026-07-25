enum ChannelType { text, voice }

enum ChannelEncryptionMode { legacy, e2ee, unsupported }

class ChatChannel {
  final String id;
  final String serverId;
  final String name;
  final ChannelType type;
  final int position;
  final String? glyph;
  final DateTime? createdAt;
  final ChannelEncryptionMode encryptionMode;
  final int encryptionVersion;

  const ChatChannel({
    required this.id,
    required this.serverId,
    required this.name,
    required this.type,
    this.position = 0,
    this.glyph,
    this.createdAt,
    this.encryptionMode = ChannelEncryptionMode.legacy,
    this.encryptionVersion = 0,
  });

  bool get allowsPlaintextMessaging =>
      encryptionMode == ChannelEncryptionMode.legacy && encryptionVersion == 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'name': name,
    'type': type.name,
    'position': position,
    'glyph': glyph,
    'createdAt': createdAt?.toIso8601String(),
    'encryptionMode': encryptionMode.name,
    'encryptionVersion': encryptionVersion,
  };

  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    final rawEncryptionMode = json['encryptionMode']?.toString();
    return ChatChannel(
      id: json['id'].toString(),
      serverId: json['serverId'].toString(),
      name: json['name'] as String,
      type: ChannelType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => ChannelType.text,
      ),
      position: (json['position'] as num?)?.toInt() ?? 0,
      glyph: (json['glyph'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['glyph'] as String).trim(),
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      encryptionMode: switch (rawEncryptionMode) {
        null => ChannelEncryptionMode.legacy,
        'legacy' => ChannelEncryptionMode.legacy,
        'e2ee' => ChannelEncryptionMode.e2ee,
        _ => ChannelEncryptionMode.unsupported,
      },
      encryptionVersion: (json['encryptionVersion'] as num?)?.toInt() ?? 0,
    );
  }
}
