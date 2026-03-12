import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;

import 'audio_preferences.dart';

enum VoiceTransportQualityPreset {
  lowLatency,
  balanced,
  highQuality,
}

typedef VoiceTransportIceCandidateCallback = FutureOr<void> Function(
  String peerId,
  RTCIceCandidate candidate,
);

class VoiceTransportPeerState {
  final String peerId;
  final bool hasRemoteAudio;
  final bool connected;
  final String connectionState;
  final String iceState;
  final String? error;

  const VoiceTransportPeerState({
    required this.peerId,
    required this.hasRemoteAudio,
    required this.connected,
    required this.connectionState,
    required this.iceState,
    this.error,
  });

  VoiceTransportPeerState copyWith({
    bool? hasRemoteAudio,
    bool? connected,
    String? connectionState,
    String? iceState,
    String? error,
    bool clearError = false,
  }) {
    return VoiceTransportPeerState(
      peerId: peerId,
      hasRemoteAudio: hasRemoteAudio ?? this.hasRemoteAudio,
      connected: connected ?? this.connected,
      connectionState: connectionState ?? this.connectionState,
      iceState: iceState ?? this.iceState,
      error: clearError ? null : (error ?? this.error),
    );
  }

  static VoiceTransportPeerState initial(String peerId) {
    return VoiceTransportPeerState(
      peerId: peerId,
      hasRemoteAudio: false,
      connected: false,
      connectionState: 'disconnected',
      iceState: 'unknown',
    );
  }
}

class VoiceTransportSnapshot {
  final bool initialized;
  final bool joining;
  final bool joined;
  final bool microphoneReady;
  final bool localTrackEnabled;
  final bool remoteAudioAttached;
  final VoiceTransportQualityPreset qualityPreset;
  final String? localPeerId;
  final String? voiceChannelId;
  final String? error;
  final Map<String, VoiceTransportPeerState> peers;

  const VoiceTransportSnapshot({
    required this.initialized,
    required this.joining,
    required this.joined,
    required this.microphoneReady,
    required this.localTrackEnabled,
    required this.remoteAudioAttached,
    required this.qualityPreset,
    required this.localPeerId,
    required this.voiceChannelId,
    required this.error,
    required this.peers,
  });

  const VoiceTransportSnapshot.idle()
      : initialized = false,
        joining = false,
        joined = false,
        microphoneReady = false,
        localTrackEnabled = false,
        remoteAudioAttached = false,
        qualityPreset = VoiceTransportQualityPreset.lowLatency,
        localPeerId = null,
        voiceChannelId = null,
        error = null,
        peers = const {};

  VoiceTransportSnapshot copyWith({
    bool? initialized,
    bool? joining,
    bool? joined,
    bool? microphoneReady,
    bool? localTrackEnabled,
    bool? remoteAudioAttached,
    VoiceTransportQualityPreset? qualityPreset,
    String? localPeerId,
    String? voiceChannelId,
    String? error,
    bool clearError = false,
    Map<String, VoiceTransportPeerState>? peers,
    bool clearLocalPeerId = false,
    bool clearVoiceChannelId = false,
  }) {
    return VoiceTransportSnapshot(
      initialized: initialized ?? this.initialized,
      joining: joining ?? this.joining,
      joined: joined ?? this.joined,
      microphoneReady: microphoneReady ?? this.microphoneReady,
      localTrackEnabled: localTrackEnabled ?? this.localTrackEnabled,
      remoteAudioAttached: remoteAudioAttached ?? this.remoteAudioAttached,
      qualityPreset: qualityPreset ?? this.qualityPreset,
      localPeerId: clearLocalPeerId ? null : (localPeerId ?? this.localPeerId),
      voiceChannelId:
          clearVoiceChannelId ? null : (voiceChannelId ?? this.voiceChannelId),
      error: clearError ? null : (error ?? this.error),
      peers: peers ?? this.peers,
    );
  }
}

class VoiceTransportService extends ChangeNotifier {
  VoiceTransportSnapshot _snapshot = const VoiceTransportSnapshot.idle();
  livekit.Room? _room;
  bool _liveKitInitialized = false;

  VoiceTransportIceCandidateCallback? onLocalIceCandidate;

  VoiceTransportSnapshot get snapshot => _snapshot;
  bool get initialized => _snapshot.initialized;
  bool get joined => _snapshot.joined;
  bool get joining => _snapshot.joining;
  bool get microphoneReady => _snapshot.microphoneReady;
  bool get localTrackEnabled => _snapshot.localTrackEnabled;
  String? get localPeerId => _snapshot.localPeerId;
  String? get voiceChannelId => _snapshot.voiceChannelId;
  Map<String, VoiceTransportPeerState> get peers => _snapshot.peers;
  String? get error => _snapshot.error;

  bool hasPeer(String peerId) => _snapshot.peers.containsKey(peerId);

  livekit.AudioCaptureOptions _audioCaptureOptions() {
    final preferredInputDeviceId = YappaAudioPreferences.preferredInputDeviceId;

    return livekit.AudioCaptureOptions(
      deviceId: preferredInputDeviceId != null &&
              preferredInputDeviceId.trim().isNotEmpty
          ? preferredInputDeviceId
          : null,
      echoCancellation: YappaAudioPreferences.echoCancellation,
      noiseSuppression: YappaAudioPreferences.noiseSuppression,
      autoGainControl: YappaAudioPreferences.autoGainControl,
      stopAudioCaptureOnMute: false,
      highPassFilter: false,
      voiceIsolation: true,
      typingNoiseDetection: true,
    );
  }

  Future<void> initialize({
    VoiceTransportQualityPreset preset = VoiceTransportQualityPreset.lowLatency,
  }) async {
    await YappaAudioPreferences.load();

    if (!_liveKitInitialized) {
      await livekit.LiveKitClient.initialize();
      _liveKitInitialized = true;
    }

    _updateSnapshot(
      _snapshot.copyWith(
        initialized: true,
        qualityPreset: preset,
        clearError: true,
      ),
    );
  }

  Future<void> joinVoiceChannel({
    required String localPeerId,
    required String voiceChannelId,
    required String serverUrl,
    required String participantToken,
    String? roomName,
    VoiceTransportQualityPreset? preset,
  }) async {
    final desiredPreset = preset ?? _snapshot.qualityPreset;

    if (_snapshot.joined &&
        _snapshot.localPeerId == localPeerId &&
        _snapshot.voiceChannelId == voiceChannelId) {
      return;
    }

    await initialize(preset: desiredPreset);
    await leaveVoiceChannel();

    _updateSnapshot(
      _snapshot.copyWith(
        joining: true,
        joined: false,
        localPeerId: localPeerId,
        voiceChannelId: voiceChannelId,
        qualityPreset: desiredPreset,
        clearError: true,
      ),
    );

    final room = livekit.Room(
      roomOptions: livekit.RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        defaultAudioCaptureOptions: _audioCaptureOptions(),
      ),
    );

    room.addListener(_handleRoomChanged);
    _room = room;

    try {
      await room.prepareConnection(serverUrl, participantToken);
      await room.connect(
        serverUrl,
        participantToken,
        connectOptions: const livekit.ConnectOptions(
          autoSubscribe: true,
        ),
      );

      final localParticipant = room.localParticipant;
      if (localParticipant == null) {
        throw Exception('LiveKit connected without a local participant.');
      }

      await localParticipant.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _audioCaptureOptions(),
      );

      try {
        await room.startAudio();
      } catch (_) {}

      await _applyPreferredOutputDeviceBestEffort();
      _refreshSnapshotFromRoom(clearError: true);
    } catch (error) {
      await _teardownRoom();
      _updateSnapshot(
        _snapshot.copyWith(
          joining: false,
          joined: false,
          microphoneReady: false,
          localTrackEnabled: false,
          remoteAudioAttached: false,
          peers: const {},
          error: 'Could not join LiveKit voice transport: $error',
        ),
      );
      rethrow;
    }
  }

  Future<void> leaveVoiceChannel() async {
    await _teardownRoom();
    _updateSnapshot(
      _snapshot.copyWith(
        joining: false,
        joined: false,
        microphoneReady: false,
        localTrackEnabled: false,
        remoteAudioAttached: false,
        peers: const {},
        clearError: true,
        clearLocalPeerId: true,
        clearVoiceChannelId: true,
      ),
    );
  }

  Future<void> setMuted(bool muted) async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (room == null || localParticipant == null) {
      return;
    }

    final audioPublications = localParticipant.audioTrackPublications;
    if (audioPublications.isEmpty) {
      await localParticipant.setMicrophoneEnabled(
        !muted,
        audioCaptureOptions: _audioCaptureOptions(),
      );
      _refreshSnapshotFromRoom(clearError: true);
      return;
    }

    for (final publication in audioPublications) {
      if (muted) {
        await publication.mute(stopOnMute: false);
      } else {
        await publication.unmute(stopOnMute: false);
      }
    }

    _refreshSnapshotFromRoom(clearError: true);
  }

  Future<void> setQualityPreset(VoiceTransportQualityPreset preset) async {
    if (_snapshot.qualityPreset == preset) return;

    _updateSnapshot(
      _snapshot.copyWith(
        qualityPreset: preset,
        clearError: true,
      ),
    );
  }

  Future<void> refreshAudioPreferences() async {
    await YappaAudioPreferences.load();
    await _applyPreferredOutputDeviceBestEffort();
    await _reapplyActiveAudioCaptureOptionsBestEffort();
    _refreshSnapshotFromRoom(clearError: true);
  }

  Future<RTCSessionDescription> createOfferForPeer(String peerId) async {
    throw UnsupportedError(
      'Yappa now uses LiveKit SFU transport, not manual peer offers.',
    );
  }

  Future<RTCSessionDescription> createAnswerForPeer(String peerId) async {
    throw UnsupportedError(
      'Yappa now uses LiveKit SFU transport, not manual peer answers.',
    );
  }

  Future<void> applyRemoteOffer({
    required String peerId,
    required RTCSessionDescription description,
  }) async {}

  Future<void> applyRemoteAnswer({
    required String peerId,
    required RTCSessionDescription description,
  }) async {}

  Future<void> addRemoteIceCandidate({
    required String peerId,
    required RTCIceCandidate candidate,
  }) async {}

  Future<void> removePeer(String peerId) async {
    // LiveKit manages participant lifecycle through the SFU automatically.
    _refreshSnapshotFromRoom(clearError: true);
  }

  void _handleRoomChanged() {
    _refreshSnapshotFromRoom();
  }

  void _refreshSnapshotFromRoom({bool clearError = false}) {
    final room = _room;
    if (room == null) {
      _updateSnapshot(
        _snapshot.copyWith(
          joined: false,
          joining: false,
          microphoneReady: false,
          localTrackEnabled: false,
          remoteAudioAttached: false,
          peers: const {},
          clearError: clearError,
        ),
      );
      return;
    }

    final remotePeerStates = <String, VoiceTransportPeerState>{};
    for (final participant in room.remoteParticipants.values) {
      final peerId = participant.identity;
      final hasRemoteAudio = participant.audioTrackPublications.any(
        (publication) => publication.subscribed &&
            !publication.muted &&
            publication.track != null,
      );

      final connected = participant.state == livekit.ParticipantState.active ||
          participant.state == livekit.ParticipantState.joined;

      remotePeerStates[peerId] = VoiceTransportPeerState(
        peerId: peerId,
        hasRemoteAudio: hasRemoteAudio,
        connected: connected,
        connectionState: participant.state.name,
        iceState: participant.connectionQuality.name,
        error: participant.connectionQuality == livekit.ConnectionQuality.lost
            ? 'Connection quality lost.'
            : null,
      );
    }

    final localParticipant = room.localParticipant;
    final localAudioPublications =
        localParticipant?.audioTrackPublications ?? const [];
    final microphoneReady = localAudioPublications.isNotEmpty;
    final localTrackEnabled = localAudioPublications.any(
      (publication) => !publication.muted && publication.track != null,
    );

    _updateSnapshot(
      _snapshot.copyWith(
        joining: room.connectionState == livekit.ConnectionState.connecting,
        joined: room.connectionState == livekit.ConnectionState.connected,
        microphoneReady: microphoneReady,
        localTrackEnabled: localTrackEnabled,
        remoteAudioAttached:
            remotePeerStates.values.any((peer) => peer.hasRemoteAudio),
        peers: remotePeerStates,
        clearError: clearError,
      ),
    );
  }


  Future<void> _reapplyActiveAudioCaptureOptionsBestEffort() async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (room == null || localParticipant == null) {
      return;
    }

    final captureOptions = _audioCaptureOptions();
    final audioPublications = localParticipant.audioTrackPublications;

    if (audioPublications.isEmpty) {
      if (_snapshot.localTrackEnabled || _snapshot.microphoneReady) {
        try {
          await localParticipant.setMicrophoneEnabled(
            true,
            audioCaptureOptions: captureOptions,
          );
        } catch (_) {}
      }
      return;
    }

    for (final publication in audioPublications) {
      final track = publication.track;
      if (track is! livekit.LocalAudioTrack) {
        continue;
      }

      try {
        await track.restartTrack(captureOptions);
      } catch (_) {
        try {
          final wasMuted = publication.muted;
          if (!wasMuted) {
            await publication.mute(stopOnMute: true);
          }
          await track.restartTrack(captureOptions);
          if (!wasMuted) {
            await publication.unmute(stopOnMute: false);
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _applyPreferredOutputDeviceBestEffort() async {
    final room = _room;
    if (room == null) return;

    await YappaAudioPreferences.load();

    final preferredOutputDeviceId =
        YappaAudioPreferences.preferredOutputDeviceId;
    if (preferredOutputDeviceId == null ||
        preferredOutputDeviceId.trim().isEmpty) {
      return;
    }

    try {
      livekit.MediaDevice? selectedDevice;

      final outputs = await livekit.Hardware.instance.audioOutputs();
      for (final device in outputs) {
        if (device.deviceId == preferredOutputDeviceId) {
          selectedDevice = device;
          break;
        }
      }

      await room.setAudioOutputDevice(
        selectedDevice ??
            livekit.MediaDevice(
              preferredOutputDeviceId,
              'Preferred output',
              'audiooutput',
              null,
            ),
      );
    } catch (_) {}
  }

  Future<void> _teardownRoom() async {
    final room = _room;
    _room = null;
    if (room == null) {
      return;
    }

    room.removeListener(_handleRoomChanged);

    try {
      await room.disconnect();
    } catch (_) {}

    try {
      await room.dispose();
    } catch (_) {}
  }

  void _updateSnapshot(VoiceTransportSnapshot next) {
    _snapshot = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(leaveVoiceChannel());
    super.dispose();
  }
}
