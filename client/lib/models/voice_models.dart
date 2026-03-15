class VoicePresenceState {
  final bool micMuted;
  final bool audioMuted;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final bool speaking;

  const VoicePresenceState({
    required this.micMuted,
    required this.audioMuted,
    required this.cameraEnabled,
    required this.screenShareEnabled,
    required this.speaking,
  });

  const VoicePresenceState.defaults()
      : micMuted = false,
        audioMuted = false,
        cameraEnabled = false,
        screenShareEnabled = false,
        speaking = false;

  factory VoicePresenceState.fromJson(Map<String, dynamic> json) {
    return VoicePresenceState(
      micMuted: json['micMuted'] == true,
      audioMuted: json['audioMuted'] == true,
      cameraEnabled: json['cameraEnabled'] == true,
      screenShareEnabled: json['screenShareEnabled'] == true,
      speaking: json['speaking'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'micMuted': micMuted,
      'audioMuted': audioMuted,
      'cameraEnabled': cameraEnabled,
      'screenShareEnabled': screenShareEnabled,
      'speaking': speaking,
    };
  }

  VoicePresenceState copyWith({
    bool? micMuted,
    bool? audioMuted,
    bool? cameraEnabled,
    bool? screenShareEnabled,
    bool? speaking,
  }) {
    return VoicePresenceState(
      micMuted: micMuted ?? this.micMuted,
      audioMuted: audioMuted ?? this.audioMuted,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      screenShareEnabled: screenShareEnabled ?? this.screenShareEnabled,
      speaking: speaking ?? this.speaking,
    );
  }
}

class VoiceDeckState {
  final String channelId;
  final String channelName;
  final int occupancy;
  final DateTime? activeSince;

  const VoiceDeckState({
    required this.channelId,
    required this.channelName,
    required this.occupancy,
    required this.activeSince,
  });

  factory VoiceDeckState.fromJson(Map<String, dynamic> json) {
    return VoiceDeckState(
      channelId: (json['channelId'] ?? '').toString(),
      channelName: (json['channelName'] ?? '').toString(),
      occupancy: switch (json['occupancy']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      activeSince: json['activeSince'] == null
          ? null
          : DateTime.tryParse(json['activeSince'].toString()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'channelId': channelId,
      'channelName': channelName,
      'occupancy': occupancy,
      'activeSince': activeSince?.toIso8601String(),
    };
  }

  VoiceDeckState copyWith({
    String? channelId,
    String? channelName,
    int? occupancy,
    DateTime? activeSince,
    bool clearActiveSince = false,
  }) {
    return VoiceDeckState(
      channelId: channelId ?? this.channelId,
      channelName: channelName ?? this.channelName,
      occupancy: occupancy ?? this.occupancy,
      activeSince: clearActiveSince ? null : (activeSince ?? this.activeSince),
    );
  }
}