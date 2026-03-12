import 'voice_models.dart';

class Member {
  final String id;
  final String username;
  final String name;
  final String role;
  final bool isOnline;
  final String status;
  final String? voiceChannelId;
  final DateTime? voiceJoinedAt;
  final VoicePresenceState voiceState;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;

  const Member({
    required this.id,
    required this.username,
    required this.name,
    required this.role,
    required this.isOnline,
    required this.status,
    required this.voiceChannelId,
    required this.voiceJoinedAt,
    required this.voiceState,
    required this.createdAt,
    required this.lastLoginAt,
  });

  bool get isOwner => role == 'owner';
  bool get isInVoiceDeck =>
      voiceChannelId != null && voiceChannelId!.trim().isNotEmpty;
  bool get isSpeaking => voiceState.speaking;

  factory Member.fromJson(Map<String, dynamic> json) {
    return Member(
      id: (json['id'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
      name: (json['name'] ?? json['username'] ?? '').toString(),
      role: (json['role'] ?? 'member').toString(),
      isOnline: json['isOnline'] == true,
      status: (json['status'] ?? 'offline').toString(),
      voiceChannelId: json['voiceChannelId']?.toString(),
      voiceJoinedAt: json['voiceJoinedAt'] == null
          ? null
          : DateTime.tryParse(json['voiceJoinedAt'].toString()),
      voiceState: json['voiceState'] is Map<String, dynamic>
          ? VoicePresenceState.fromJson(json['voiceState'] as Map<String, dynamic>)
          : json['voiceState'] is Map
              ? VoicePresenceState.fromJson(
                  Map<String, dynamic>.from(json['voiceState'] as Map),
                )
              : const VoicePresenceState.defaults(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.tryParse(json['createdAt'].toString()),
      lastLoginAt: json['lastLoginAt'] == null
          ? null
          : DateTime.tryParse(json['lastLoginAt'].toString()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'role': role,
      'isOnline': isOnline,
      'status': status,
      'voiceChannelId': voiceChannelId,
      'voiceJoinedAt': voiceJoinedAt?.toIso8601String(),
      'voiceState': voiceState.toJson(),
      'createdAt': createdAt?.toIso8601String(),
      'lastLoginAt': lastLoginAt?.toIso8601String(),
    };
  }

  Member copyWith({
    String? id,
    String? username,
    String? name,
    String? role,
    bool? isOnline,
    String? status,
    String? voiceChannelId,
    DateTime? voiceJoinedAt,
    VoicePresenceState? voiceState,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    bool clearVoiceChannelId = false,
    bool clearVoiceJoinedAt = false,
  }) {
    return Member(
      id: id ?? this.id,
      username: username ?? this.username,
      name: name ?? this.name,
      role: role ?? this.role,
      isOnline: isOnline ?? this.isOnline,
      status: status ?? this.status,
      voiceChannelId:
          clearVoiceChannelId ? null : (voiceChannelId ?? this.voiceChannelId),
      voiceJoinedAt:
          clearVoiceJoinedAt ? null : (voiceJoinedAt ?? this.voiceJoinedAt),
      voiceState: voiceState ?? this.voiceState,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
    );
  }
}