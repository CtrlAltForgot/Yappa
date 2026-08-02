import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/yappa_portal_capture.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;

import 'audio_preferences.dart';
import 'video_preferences.dart';

enum VoiceTransportQualityPreset { lowLatency, balanced, highQuality }

enum VoiceScreenShareTarget { any, screen, window }

typedef VoiceTransportIceCandidateCallback =
    FutureOr<void> Function(String peerId, RTCIceCandidate candidate);

bool mediaPublicationAllowed({
  required bool localE2eeReady,
  required bool e2eeFailed,
}) => localE2eeReady && !e2eeFailed;

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
      voiceChannelId: clearVoiceChannelId
          ? null
          : (voiceChannelId ?? this.voiceChannelId),
      error: clearError ? null : (error ?? this.error),
      peers: peers ?? this.peers,
    );
  }
}

class VoiceTransportService extends ChangeNotifier {
  VoiceTransportSnapshot _snapshot = const VoiceTransportSnapshot.idle();
  livekit.Room? _room;
  livekit.EventsListener<livekit.RoomEvent>? _roomEventsListener;
  livekit.BaseKeyProvider? _e2eeKeyProvider;
  livekit.LocalVideoTrack? _manualScreenShareTrack;
  bool _liveKitInitialized = false;
  bool _outputMuted = false;
  bool _manualScreenShareStopInProgress = false;
  bool _localE2eeReady = false;
  bool _e2eeFailed = false;
  Completer<void>? _pendingLocalE2eeReady;
  final Map<String, double> _peerVolumes = <String, double>{};
  Future<void>? _teardownFuture;
  Future<bool>? _screenShareStartFuture;

  VoiceTransportIceCandidateCallback? onLocalIceCandidate;

  VoiceTransportSnapshot get snapshot => _snapshot;
  bool get initialized => _snapshot.initialized;
  bool get joined => _snapshot.joined;
  bool get joining => _snapshot.joining;
  bool get microphoneReady => _snapshot.microphoneReady;
  bool get localTrackEnabled => _snapshot.localTrackEnabled;
  bool get localE2eeReady => _localE2eeReady;
  bool get e2eeFailed => _e2eeFailed;
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
    if (participant != null) {
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
    }

    return _manualScreenShareTrack;
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
            tracks[_participantUserId(participant)] =
                track as livekit.VideoTrack;
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
            tracks[_participantUserId(participant)] =
                track as livekit.VideoTrack;
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
      deviceId:
          preferredInputDeviceId != null &&
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
    required Uint8List encryptionKey,
    required int encryptionKeyIndex,
    required List<String> encryptionParticipantIds,
    String? roomName,
    String? lanHost,
    int? lanTlsPort,
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

    if (encryptionKey.length != 32 ||
        encryptionKeyIndex < 0 ||
        encryptionKeyIndex > 255 ||
        encryptionParticipantIds.isEmpty) {
      throw const FormatException('Invalid end-to-end media key.');
    }
    final nativeKeyOptions = KeyProviderOptions(
      sharedKey: false,
      ratchetSalt: Uint8List.fromList('YappaMediaRatchetV1'.codeUnits),
      ratchetWindowSize: 16,
      uncryptedMagicBytes: Uint8List.fromList('YAPPA-E2EE'.codeUnits),
      failureTolerance: 0,
      keyRingSize: 16,
      discardFrameWhenCryptorNotReady: true,
    );
    final nativeKeyProvider = await frameCryptorFactory
        .createDefaultKeyProvider(nativeKeyOptions);
    final e2eeKeyProvider = livekit.BaseKeyProvider(
      nativeKeyProvider,
      nativeKeyOptions,
    );
    for (final participantId in encryptionParticipantIds.toSet()) {
      await e2eeKeyProvider.setRawKey(
        Uint8List.fromList(encryptionKey),
        participantId: participantId,
        keyIndex: encryptionKeyIndex,
      );
    }
    _e2eeKeyProvider = e2eeKeyProvider;
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
        encryption: livekit.E2EEOptions(keyProvider: e2eeKeyProvider),
      ),
    );

    room.addListener(_handleRoomChanged);
    _roomEventsListener = room.createListener()
      ..on<livekit.LocalTrackUnpublishedEvent>(_handleLocalTrackUnpublished)
      ..on<livekit.TrackE2EEStateEvent>(_handleTrackE2eeState)
      ..on<livekit.RoomDisconnectedEvent>((_) {
        unawaited(_clearManualScreenShareTrack());
        _refreshSnapshotFromRoom(clearError: true);
      });
    _room = room;

    try {
      final serverUri = Uri.parse(serverUrl);
      final useSecureLanRoute =
          serverUri.scheme == 'wss' &&
          (lanHost ?? '').trim().isNotEmpty &&
          lanTlsPort != null;
      Future<void> connectRoom() async {
        await room.prepareConnection(serverUrl, participantToken);
        await room.connect(
          serverUrl,
          participantToken,
          connectOptions: const livekit.ConnectOptions(autoSubscribe: true),
        );
      }

      if (useSecureLanRoute) {
        await HttpOverrides.runZoned<Future<void>>(
          connectRoom,
          createHttpClient: (context) => _secureLanHttpClient(
            context: context,
            expectedHost: serverUri.host,
            lanHost: lanHost!,
            lanPort: lanTlsPort,
          ),
        );
      } else {
        await connectRoom();
      }

      final localParticipant = room.localParticipant;
      if (localParticipant == null) {
        throw Exception('LiveKit connected without a local participant.');
      }

      _localE2eeReady = false;
      _e2eeFailed = false;
      _pendingLocalE2eeReady = Completer<void>();
      await localParticipant.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _audioCaptureOptions(),
      );
      await _pendingLocalE2eeReady!.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException(
          'LiveKit did not confirm microphone frame encryption.',
        ),
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

  HttpClient _secureLanHttpClient({
    required SecurityContext? context,
    required String expectedHost,
    required String lanHost,
    required int lanPort,
  }) {
    final client = HttpClient(context: context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 6);
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      if (proxyHost != null ||
          proxyPort != null ||
          requestUri.host.toLowerCase() != expectedHost.toLowerCase()) {
        throw const SocketException('Invalid secure LAN media route.');
      }
      final rawTask = await Socket.startConnect(lanHost, lanPort);
      final secureSocket = rawTask.socket.then(
        (socket) => SecureSocket.secure(socket, host: requestUri.host),
      );
      return ConnectionTask.fromSocket(secureSocket, rawTask.cancel);
    };
    return client;
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
    if (!muted &&
        !mediaPublicationAllowed(
          localE2eeReady: _localE2eeReady,
          e2eeFailed: _e2eeFailed,
        )) {
      throw StateError(
        'Microphone publication requires verified media encryption.',
      );
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
    if (enabled &&
        !mediaPublicationAllowed(
          localE2eeReady: _localE2eeReady,
          e2eeFailed: _e2eeFailed,
        )) {
      throw StateError(
        'Camera publication requires verified media encryption.',
      );
    }

    await localParticipant.setCameraEnabled(enabled);
    _refreshSnapshotFromRoom(clearError: true);
  }

  Future<bool> setScreenShareEnabled(
    bool enabled, {
    VoiceScreenShareTarget preferredTarget = VoiceScreenShareTarget.any,
    String? preferredSourceId,
  }) async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (room == null || localParticipant == null) {
      return false;
    }
    if (enabled &&
        !mediaPublicationAllowed(
          localE2eeReady: _localE2eeReady,
          e2eeFailed: _e2eeFailed,
        )) {
      throw StateError(
        'Screen publication requires verified media encryption.',
      );
    }

    final existingScreenShare = localParticipant.getTrackPublicationBySource(
      livekit.TrackSource.screenShareVideo,
    );

    if (enabled &&
        existingScreenShare != null &&
        !existingScreenShare.muted &&
        localScreenShareTrack != null) {
      _refreshSnapshotFromRoom(clearError: true);
      return true;
    }

    if (!enabled) {
      _screenShareStartFuture = null;
      await _removeLocalScreenSharePublications(localParticipant);
      _refreshSnapshotFromRoom(clearError: true);
      return true;
    }

    final inFlightStart = _screenShareStartFuture;
    if (inFlightStart != null) {
      return inFlightStart;
    }

    final startFuture = _startScreenShare(
      localParticipant,
      preferredTarget: preferredTarget,
      preferredSourceId: preferredSourceId,
    );
    _screenShareStartFuture = startFuture;

    try {
      return await startFuture;
    } finally {
      if (identical(_screenShareStartFuture, startFuture)) {
        _screenShareStartFuture = null;
      }
    }
  }

  Future<bool> _startScreenShare(
    livekit.LocalParticipant localParticipant, {
    required VoiceScreenShareTarget preferredTarget,
    String? preferredSourceId,
  }) async {
    try {
      await _removeLocalScreenSharePublications(localParticipant);
      final quality = YappaVideoPreferences.screenShareQuality;
      final captureParameters = livekit.VideoParameters(
        dimensions: livekit.VideoDimensions(quality.width, quality.height),
        encoding: livekit.VideoEncoding(
          maxFramerate: quality.framesPerSecond,
          maxBitrate: quality.maxBitrate,
        ),
      );

      if (_requiresManualDesktopSourceSelection) {
        var sourceId = preferredSourceId?.trim();
        if (sourceId == null || sourceId.isEmpty) {
          final selectedSource = await _pickDesktopSource(preferredTarget);
          if (selectedSource == null) {
            _refreshSnapshotFromRoom(clearError: true);
            return false;
          }
          sourceId = selectedSource.id;
        }

        await _createAndPublishScreenShareTracks(
          localParticipant,
          livekit.ScreenShareCaptureOptions(
            sourceId: sourceId,
            maxFrameRate: quality.framesPerSecond.toDouble(),
            params: captureParameters,
            // Windows loopback capture is still unstable and can tear down the
            // entire display-capture request. Establish proven screen video
            // first; system audio remains enabled on the validated Linux path.
            captureScreenAudio: !Platform.isWindows,
          ),
        );
      } else if (_useManualNativePortalScreenShareTrack) {
        await _createAndPublishScreenShareTracks(
          localParticipant,
          livekit.ScreenShareCaptureOptions(
            sourceId: 'yappa-portal',
            maxFrameRate: quality.framesPerSecond.toDouble(),
            params: captureParameters,
            captureScreenAudio: true,
          ),
        );
      } else {
        await _createAndPublishScreenShareTracks(
          localParticipant,
          livekit.ScreenShareCaptureOptions(
            maxFrameRate: quality.framesPerSecond.toDouble(),
            params: captureParameters,
            captureScreenAudio: true,
          ),
        );
      }

      _refreshSnapshotFromRoom(clearError: true);
      return true;
    } catch (error) {
      await _clearManualScreenShareTrack();

      if (_looksLikeCaptureCancellation(error)) {
        _refreshSnapshotFromRoom(clearError: true);
        return false;
      }

      _updateSnapshot(
        _snapshot.copyWith(error: 'Could not start screen share: $error'),
      );
      rethrow;
    }
  }

  Future<void> _createAndPublishScreenShareTracks(
    livekit.LocalParticipant localParticipant,
    livekit.ScreenShareCaptureOptions captureOptions,
  ) async {
    final tracks = captureOptions.captureScreenAudio
        ? await livekit.LocalVideoTrack.createScreenShareTracksWithAudio(
            captureOptions,
          )
        : <livekit.LocalTrack>[
            await livekit.LocalVideoTrack.createScreenShareTrack(
              captureOptions,
            ),
          ];
    livekit.LocalVideoTrack? videoTrack;

    for (final track in tracks) {
      if (track is livekit.LocalVideoTrack) {
        videoTrack = track;
        _manualScreenShareTrack = track;
        await localParticipant.publishVideoTrack(
          track,
          publishOptions: livekit.VideoPublishOptions(
            screenShareEncoding: captureOptions.params.encoding,
            simulcast: true,
            degradationPreference: livekit.DegradationPreference.balanced,
          ),
        );
      } else if (track is livekit.LocalAudioTrack) {
        await localParticipant.publishAudioTrack(track);
      }
    }

    if (videoTrack == null) {
      throw Exception(
        'The screen capture backend did not create a video track.',
      );
    }

    await _waitForScreenShareFrames(videoTrack);
  }

  Future<void> _waitForScreenShareFrames(livekit.LocalVideoTrack track) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));

    while (DateTime.now().isBefore(deadline)) {
      if (!track.isActive) {
        throw Exception('Screen selection was cancelled.');
      }

      try {
        final stats = await track.getSenderStats();
        if (stats.any((item) => (item.framesSent ?? 0) > 0)) {
          debugPrint('[YappaScreenShare] WebRTC sender is delivering frames.');
          return;
        }
      } catch (_) {
        // The sender can briefly have no stats while LiveKit attaches it.
      }

      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    throw Exception(
      'Screen capture started, but no video frames were received.',
    );
  }

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get _requiresManualDesktopSourceSelection {
    if (kIsWeb) {
      return false;
    }

    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return true;
    }

    if (defaultTargetPlatform == TargetPlatform.linux) {
      return !YappaVideoPreferences.isWaylandSession;
    }

    return false;
  }

  bool get _useManualNativePortalScreenShareTrack {
    if (kIsWeb) {
      return false;
    }

    return defaultTargetPlatform == TargetPlatform.linux &&
        YappaVideoPreferences.isWaylandSession;
  }

  List<SourceType> _desktopSourceTypesFor(
    VoiceScreenShareTarget preferredTarget,
  ) {
    if (_isLinuxDesktop && YappaVideoPreferences.isWaylandSession) {
      return const <SourceType>[SourceType.Screen];
    }

    return switch (preferredTarget) {
      VoiceScreenShareTarget.window => const <SourceType>[SourceType.Window],
      VoiceScreenShareTarget.screen => const <SourceType>[SourceType.Screen],
      VoiceScreenShareTarget.any => const <SourceType>[
        SourceType.Screen,
        SourceType.Window,
      ],
    };
  }

  Future<DesktopCapturerSource?> _pickDesktopSource(
    VoiceScreenShareTarget preferredTarget,
  ) async {
    final sources = await desktopCapturer.getSources(
      types: _desktopSourceTypesFor(preferredTarget),
    );

    if (sources.isEmpty) {
      return null;
    }

    return sources.first;
  }

  Future<void> _removeLocalScreenSharePublications(
    livekit.LocalParticipant localParticipant,
  ) async {
    _manualScreenShareStopInProgress = true;

    try {
      final screenVideoPublication = localParticipant
          .getTrackPublicationBySource(livekit.TrackSource.screenShareVideo);
      if (screenVideoPublication != null) {
        await localParticipant.removePublishedTrack(screenVideoPublication.sid);
      }

      final screenAudioPublication = localParticipant
          .getTrackPublicationBySource(livekit.TrackSource.screenShareAudio);
      if (screenAudioPublication != null) {
        await localParticipant.removePublishedTrack(screenAudioPublication.sid);
      }
    } finally {
      _manualScreenShareStopInProgress = false;
      await _clearManualScreenShareTrack();
    }
  }

  Future<void> _clearManualScreenShareTrack() async {
    final track = _manualScreenShareTrack;
    _manualScreenShareTrack = null;

    if (track != null) {
      try {
        await track.stop();
      } catch (_) {}

      try {
        await track.dispose();
      } catch (_) {}
    }

    if (_useManualNativePortalScreenShareTrack) {
      try {
        await YappaPortalCapture.stop();
      } catch (_) {}
    }
  }

  void _handleLocalTrackUnpublished(livekit.LocalTrackUnpublishedEvent event) {
    if (event.publication.source != livekit.TrackSource.screenShareVideo) {
      return;
    }

    debugPrint(
      '[YappaScreenShare] Local screen track unpublished '
      '(manualStop=$_manualScreenShareStopInProgress).',
    );
    if (!_manualScreenShareStopInProgress) {
      unawaited(_clearManualScreenShareTrack());
    }
    _refreshSnapshotFromRoom(clearError: true);
  }

  void _handleTrackE2eeState(livekit.TrackE2EEStateEvent event) {
    final room = _room;
    if (room == null) return;
    final isLocal =
        event.participant.identity == room.localParticipant?.identity;
    switch (event.state) {
      case livekit.E2EEState.kOk:
      case livekit.E2EEState.kKeyRatcheted:
        if (!isLocal) return;
        _localE2eeReady = true;
        _e2eeFailed = false;
        final pending = _pendingLocalE2eeReady;
        if (pending != null && !pending.isCompleted) {
          pending.complete();
        }
        notifyListeners();
      case livekit.E2EEState.kNew:
        break;
      case livekit.E2EEState.kMissingKey:
      case livekit.E2EEState.kEncryptionFailed:
      case livekit.E2EEState.kDecryptionFailed:
      case livekit.E2EEState.kInternalError:
        _localE2eeReady = false;
        _e2eeFailed = true;
        final pending = _pendingLocalE2eeReady;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            StateError('LiveKit frame encryption failed: ${event.state.name}'),
          );
        }
        unawaited(_stopPublishingForE2eeFailure());
        notifyListeners();
    }
  }

  Future<void> _stopPublishingForE2eeFailure() async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    try {
      await participant.setMicrophoneEnabled(false);
    } catch (_) {}
    try {
      await participant.setCameraEnabled(false);
    } catch (_) {}
    try {
      await _removeLocalScreenSharePublications(participant);
      await _clearManualScreenShareTrack();
    } catch (_) {}
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
          (entry) =>
              MapEntry(entry.key, entry.value.clamp(0.0, 1.5).toDouble()),
        ),
      );
    _peerVolumes.removeWhere((peerId, volume) => (volume - 1.0).abs() < 0.001);
    _applyOutputMuteBestEffort();
  }

  Future<void> setQualityPreset(VoiceTransportQualityPreset preset) async {
    if (_snapshot.qualityPreset == preset) return;

    _updateSnapshot(
      _snapshot.copyWith(qualityPreset: preset, clearError: true),
    );
  }

  Future<void> updateMediaEncryptionKey({
    required Uint8List key,
    required int keyIndex,
    required List<String> participantIds,
  }) async {
    final provider = _e2eeKeyProvider;
    final room = _room;
    if (provider == null || room == null) return;
    if (key.length != 32 ||
        keyIndex < 0 ||
        keyIndex > 255 ||
        participantIds.isEmpty) {
      throw const FormatException('Invalid end-to-end media key update.');
    }
    _localE2eeReady = false;
    _e2eeFailed = false;
    _pendingLocalE2eeReady = Completer<void>();
    notifyListeners();
    try {
      for (final participantId in participantIds.toSet()) {
        await provider.setRawKey(
          Uint8List.fromList(key),
          participantId: participantId,
          keyIndex: keyIndex,
        );
        await room.e2eeManager?.setKeyIndex(
          keyIndex,
          participantIdentity: participantId,
        );
      }
      await _pendingLocalE2eeReady!.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException(
          'LiveKit did not confirm the rotated frame-encryption key.',
        ),
      );
    } catch (_) {
      await _stopPublishingForE2eeFailure();
      rethrow;
    }
  }

  Future<void> suspendMediaForKeyRotation({
    required int keyIndex,
    required List<String> participantIds,
  }) async {
    final random = Random.secure();
    final quarantineKey = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    try {
      await updateMediaEncryptionKey(
        key: quarantineKey,
        keyIndex: keyIndex,
        participantIds: participantIds,
      );
    } finally {
      quarantineKey.fillRange(0, quarantineKey.length, 0);
    }
  }

  Future<void> failMediaEncryption(Object error) async {
    _localE2eeReady = false;
    _e2eeFailed = true;
    final pending = _pendingLocalE2eeReady;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('End-to-end media encryption failed.'));
    }
    await _stopPublishingForE2eeFailure();
    _updateSnapshot(
      _snapshot.copyWith(
        microphoneReady: false,
        localTrackEnabled: false,
        error:
            'End-to-end media encryption failed: '
            '${error.toString().replaceFirst('FormatException: ', '')}',
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
      final peerId = _participantUserId(participant);
      final hasRemoteAudio = participant.audioTrackPublications.any(
        (publication) =>
            publication.subscribed &&
            !publication.muted &&
            publication.track != null,
      );

      final connected =
          participant.state == livekit.ParticipantState.active ||
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
        remoteAudioAttached: remotePeerStates.values.any(
          (peer) => peer.hasRemoteAudio,
        ),
        peers: remotePeerStates,
        clearError: clearError,
      ),
    );
  }

  void _applyOutputMuteBestEffort() {
    final room = _room;
    if (room == null) return;

    for (final participant in room.remoteParticipants.values) {
      final peerId = _participantUserId(participant);
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

  String _participantUserId(livekit.RemoteParticipant participant) {
    final metadata = participant.metadata;
    if (metadata != null && metadata.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(metadata);
        if (decoded is Map) {
          final userId = decoded['userId']?.toString().trim() ?? '';
          if (userId.isNotEmpty) {
            return userId;
          }
        }
      } catch (_) {}
    }
    return participant.identity;
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

    final future = () async {
      final room = _room;
      _room = null;
      _e2eeKeyProvider = null;
      _localE2eeReady = false;
      _e2eeFailed = false;
      _pendingLocalE2eeReady = null;

      _roomEventsListener?.dispose();
      _roomEventsListener = null;

      if (room == null) {
        await _clearManualScreenShareTrack();
        return;
      }

      room.removeListener(_handleRoomChanged);

      try {
        await room.disconnect();
      } catch (_) {}

      try {
        await room.dispose();
      } catch (_) {}

      await _clearManualScreenShareTrack();
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
