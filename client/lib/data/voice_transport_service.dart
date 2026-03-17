import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;

import 'audio_preferences.dart';
import 'video_preferences.dart';

enum VoiceTransportQualityPreset {
  lowLatency,
  balanced,
  highQuality,
}

enum VoiceScreenShareTarget {
  any,
  screen,
  window,
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
  bool _outputMuted = false;
  final Map<String, double> _peerVolumes = <String, double>{};
  Future<void>? _teardownFuture;

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

  livekit.VideoTrack? get localCameraTrack {
    final participant = _room?.localParticipant;
    if (participant == null) {
      return null;
    }

    for (final publication in participant.videoTrackPublications) {
      if (publication.source == livekit.TrackSource.camera) {
        final track = publication.track;
        if (track != null) {
          return track;
        }
      }
    }

    return null;
  }

  livekit.VideoTrack? get localScreenShareTrack {
    final participant = _room?.localParticipant;
    if (participant == null) {
      return null;
    }

    for (final publication in participant.videoTrackPublications) {
      if (publication.source == livekit.TrackSource.screenShareVideo) {
        if (publication.muted) {
          continue;
        }
        final track = publication.track;
        if (track != null) {
          return track;
        }
      }
    }

    return null;
  }

  Map<String, livekit.VideoTrack> get remoteCameraTracks {
    final room = _room;
    if (room == null) {
      return const {};
    }

    final tracks = <String, livekit.VideoTrack>{};

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        if (publication.source == livekit.TrackSource.camera) {
          final track = publication.track;
          if (track != null) {
            tracks[participant.identity] = track as livekit.VideoTrack;
          }
          break;
        }
      }
    }

    return Map.unmodifiable(tracks);
  }

  Map<String, livekit.VideoTrack> get remoteScreenShareTracks {
    final room = _room;
    if (room == null) {
      return const {};
    }

    final tracks = <String, livekit.VideoTrack>{};

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        if (publication.source == livekit.TrackSource.screenShareVideo) {
          if (publication.muted) {
            continue;
          }
          final track = publication.track;
          if (track != null) {
            tracks[participant.identity] = track as livekit.VideoTrack;
          }
          break;
        }
      }
    }

    return Map.unmodifiable(tracks);
  }

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
        adaptiveStream: true,
        dynacast: true,
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

  Future<void> setCameraEnabled(bool enabled) async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (room == null || localParticipant == null) {
      return;
    }

    await localParticipant.setCameraEnabled(enabled);
    _refreshSnapshotFromRoom(clearError: true);
  }

  Future<bool> setScreenShareEnabled(
    bool enabled, {
    VoiceScreenShareTarget preferredTarget = VoiceScreenShareTarget.any,
  }) async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (room == null || localParticipant == null) {
      return false;
    }

    final existingScreenShare = localParticipant.getTrackPublicationBySource(
      livekit.TrackSource.screenShareVideo,
    );

    if (enabled && existingScreenShare != null && !existingScreenShare.muted) {
      _refreshSnapshotFromRoom(clearError: true);
      return true;
    }

    if (!enabled) {
      final screenVideoPublication = localParticipant.getTrackPublicationBySource(
        livekit.TrackSource.screenShareVideo,
      );
      if (screenVideoPublication != null) {
        await localParticipant.removePublishedTrack(screenVideoPublication.sid);
      }

      final screenAudioPublication = localParticipant.getTrackPublicationBySource(
        livekit.TrackSource.screenShareAudio,
      );
      if (screenAudioPublication != null) {
        await localParticipant.removePublishedTrack(screenAudioPublication.sid);
      }

      _refreshSnapshotFromRoom(clearError: true);
      return true;
    }

    try {
      final started = _isLinuxDesktop
          ? await _enableLinuxScreenShare(
              localParticipant,
              preferredTarget: preferredTarget,
            )
          : await _enableStandardScreenShare(localParticipant);

      if (!started) {
        _refreshSnapshotFromRoom(clearError: true);
        return false;
      }

      _refreshSnapshotFromRoom(clearError: true);
      return true;
    } catch (error) {
      if (_looksLikeCaptureCancellation(error)) {
        _refreshSnapshotFromRoom(clearError: true);
        return false;
      }

      _updateSnapshot(
        _snapshot.copyWith(
          error: 'Could not start screen share: $error',
        ),
      );
      rethrow;
    }
  }

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  Future<bool> _enableStandardScreenShare(
    livekit.LocalParticipant localParticipant,
  ) async {
    await localParticipant.setScreenShareEnabled(
      true,
      captureScreenAudio: false,
      screenShareCaptureOptions: const livekit.ScreenShareCaptureOptions(
        maxFrameRate: 15.0,
      ),
    );

    return true;
  }

  Future<bool> _enableLinuxScreenShare(
    livekit.LocalParticipant localParticipant, {
    required VoiceScreenShareTarget preferredTarget,
  }) async {
    final backend = YappaVideoPreferences.linuxScreenShareBackend;
    final blockMessage = YappaVideoPreferences.linuxScreenShareBlockMessage();

    if (blockMessage != null) {
      throw StateError(blockMessage);
    }

    final shouldTryNativeFirst = switch (backend) {
      YappaLinuxScreenShareBackend.auto => true,
      YappaLinuxScreenShareBackend.nativePortal => true,
      YappaLinuxScreenShareBackend.x11Only => false,
      YappaLinuxScreenShareBackend.disableOnWayland =>
        !YappaVideoPreferences.isWaylandSession,
    };

    final allowLegacyX11Fallback = switch (backend) {
      YappaLinuxScreenShareBackend.auto => YappaVideoPreferences.isX11Session,
      YappaLinuxScreenShareBackend.nativePortal => false,
      YappaLinuxScreenShareBackend.x11Only => YappaVideoPreferences.isX11Session,
      YappaLinuxScreenShareBackend.disableOnWayland => false,
    };

    Object? nativeFailure;

    if (shouldTryNativeFirst) {
      try {
        return await _enableStandardScreenShare(localParticipant);
      } catch (error) {
        nativeFailure = error;

        if (!allowLegacyX11Fallback || !_canFallbackFromLinuxPortalError(error)) {
          rethrow;
        }
      }
    }

    if (allowLegacyX11Fallback) {
      final selectedSource = await _pickLinuxDesktopSource(preferredTarget);
      if (selectedSource == null) {
        return false;
      }

      final track = await livekit.LocalVideoTrack.createScreenShareTrack(
        livekit.ScreenShareCaptureOptions(
          sourceId: selectedSource.id,
          maxFrameRate: 15.0,
        ),
      );

      await localParticipant.publishVideoTrack(track);
      return true;
    }

    if (nativeFailure != null) {
      throw nativeFailure;
    }

    throw StateError('Screen sharing is unavailable for the current Linux session.');
  }

  bool _canFallbackFromLinuxPortalError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('getdisplaymedia') ||
        message.contains('source not found') ||
        message.contains('portal') ||
        message.contains('screencast') ||
        message.contains('not supported') ||
        message.contains('not implemented');
  }

  Future<DesktopCapturerSource?> _pickLinuxDesktopSource(
    VoiceScreenShareTarget preferredTarget,
  ) async {
    final types = switch (preferredTarget) {
      VoiceScreenShareTarget.window => <SourceType>[SourceType.Window],
      VoiceScreenShareTarget.screen => <SourceType>[SourceType.Screen],
      VoiceScreenShareTarget.any => <SourceType>[SourceType.Screen],
    };

    final sources = await desktopCapturer.getSources(
      types: types,
    );

    if (sources.isEmpty) {
      return null;
    }

    return sources.first;
  }

  bool _looksLikeCaptureCancellation(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('cancel') ||
        message.contains('denied') ||
        message.contains('dismissed') ||
        message.contains('notallowederror') ||
        message.contains('aborterror') ||
        message.contains('permission') ||
        message.contains('closed by user');
  }

  Future<void> setOutputMuted(bool muted) async {
    _outputMuted = muted;
    _applyOutputMuteBestEffort();
    _refreshSnapshotFromRoom(clearError: true);
  }

  double peerVolumeFor(String peerId) {
    final stored = _peerVolumes[peerId];
    if (stored == null) {
      return 1.0;
    }
    return stored.clamp(0.0, 1.5).toDouble();
  }

  Future<void> setPeerVolume(String peerId, double volume) async {
    final safeVolume = volume.clamp(0.0, 1.5).toDouble();
    if ((safeVolume - 1.0).abs() < 0.001) {
      _peerVolumes.remove(peerId);
    } else {
      _peerVolumes[peerId] = safeVolume;
    }
    _applyOutputMuteBestEffort();
  }

  Future<void> replacePeerVolumes(Map<String, double> volumes) async {
    _peerVolumes
      ..clear()
      ..addEntries(
        volumes.entries.map(
          (entry) => MapEntry(
            entry.key,
            entry.value.clamp(0.0, 1.5).toDouble(),
          ),
        ),
      );
    _peerVolumes.removeWhere(
      (peerId, volume) => (volume - 1.0).abs() < 0.001,
    );
    _applyOutputMuteBestEffort();
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
    _applyOutputMuteBestEffort();
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

    _applyOutputMuteBestEffort();

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

  void _applyOutputMuteBestEffort() {
    final room = _room;
    if (room == null) return;

    for (final participant in room.remoteParticipants.values) {
      final peerId = participant.identity;
      final gain = _outputMuted ? 0.0 : peerVolumeFor(peerId);

      try {
        (participant as dynamic).setVolume(gain);
      } catch (_) {}

      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        try {
          (track as dynamic).setVolume(gain);
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
    final inFlight = _teardownFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final room = _room;
    _room = null;
    if (room == null) {
      return;
    }

    final future = () async {
      room.removeListener(_handleRoomChanged);

      try {
        await room.disconnect();
      } catch (_) {}
    }();

    _teardownFuture = future;
    try {
      await future;
    } finally {
      _teardownFuture = null;
    }
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