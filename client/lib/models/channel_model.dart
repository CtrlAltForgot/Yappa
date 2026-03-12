enum ChannelType { text, voice }

class ChatChannel {
  final String id;
  final String serverId;
  final String name;
  final ChannelType type;
  final int position;
  final DateTime? createdAt;

  const ChatChannel({
    required this.id,
    required this.serverId,
    required this.name,
    required this.type,
    this.position = 0,
    this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'name': name,
        'type': type.name,
        'position': position,
        'createdAt': createdAt?.toIso8601String(),
      };

  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    return ChatChannel(
      id: json['id'].toString(),
      serverId: json['serverId'].toString(),
      name: json['name'] as String,
      type: ChannelType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => ChannelType.text,
      ),
      position: (json['position'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
    );
  }
}