import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/audio_preferences.dart';
import '../data/mic_input_service.dart';
import '../data/realtime_client.dart';
import '../data/voice_transport_service.dart';
import '../data/yuid_identity_service.dart';
import '../data/video_preferences.dart';
import '../models/channel_model.dart';
import '../models/member_model.dart';
import '../models/link_preview_model.dart';
import '../models/message_model.dart';
import '../models/server_model.dart';
import '../models/server_permissions.dart';
import '../models/voice_models.dart';

class AppState extends ChangeNotifier {
  static const _serversKey = 'yappa_servers';
  static const _channelsKey = 'yappa_channels';
  static const _membersKey = 'yappa_members';
  static const _messagesKey = 'yappa_messages';
  static const _tokensKey = 'yappa_tokens';
  static const _rememberedUsersKey = 'yappa_authenticated_users';
  static const _activeServerIdKey = 'yappa_active_server_id';
  static const _currentUsernameKey = 'yappa_current_username';
  static const _selectedServerIdKey = 'yappa_selected_server_id';
  static const _selectedChannelIdKey = 'yappa_selected_channel_id';
  static const _localProfilesKey = 'yappa_local_profiles';
  static const _globalYuidKey = 'yappa_global_yuid';
  static const _voiceMemberVolumesKey = 'yappa_voice_member_volumes';

  final ApiClient _api = ApiClient();
  final YuidIdentityService _yuidIdentity = YuidIdentityService();
  final MicInputService _micInput = MicInputService();
  final VoiceTransportService _voiceTransport = VoiceTransportService();

  final Map<String, Future<LinkPreview?>> _linkPreviewCache = {};

  final List<ChatServer> _servers;
  final List<ChatChannel> _channels;
  final Map<String, List<Member>> _membersByServer;
  final Map<String, List<ChatMessage>> _messagesByChannel;
  final Map<String, String> _tokensByServerId;
  final Map<String, String> _rememberedUsersByServer;
  final Map<String, ServerPermissions> _permissionsByServerId;
  final Map<String, ServerSettings> _serverSettingsByServerId;
  final Map<String, String> _userIdByServerId;
  final Map<String, List<VoiceDeckState>> _voiceDeckStatesByServerId;
  final Map<String, VoicePresenceState> _localVoiceStateByServerId;
  final Map<String, bool> _audioMuteAutoMutedMicByServerId = {};
  final Map<String, String> _localDisplayNamesByAccount = {};
  final Map<String, String> _localAvatarSourcesByAccount = {};
  final Map<String, Map<String, double>> _voiceMemberVolumesByServerId = {};

  RealtimeClient? _realtime;
  Timer? _voiceActivityReleaseTimer;
  final bool _voiceActivityEnabled = true;
  bool _voiceActivityPttOverride = false;
  bool? _lastAppliedTransportMuted;
  bool _voiceTransportMuteSyncRunning = false;
  bool _voiceTransportMuteSyncQueued = false;
  final Set<String> _voiceOfferInFlightPeerIds = {};

  static const double _defaultVoiceActivityStartThreshold = 0.12;
  static const double _defaultVoiceActivityStopThreshold = 0.06;
  static const Duration _voiceActivityReleaseDelay =
      Duration(milliseconds: 240);

  String? _currentUsername;
  String? _activeServerId;
  String? _selectedServerId;
  String? _selectedChannelId;
  String? _lastError;
  bool _isBusy = false;
  String? _globalYuid;
  bool _screenShareSelectionPending = false;

  AppState._({
    required List<ChatServer> servers,
    required List<ChatChannel> channels,
    required Map<String, List<Member>> membersByServer,
    required Map<String, List<ChatMessage>> messagesByChannel,
    required Map<String, String> tokensByServerId,
    required Map<String, String> rememberedUsersByServer,
    required Map<String, ServerPermissions> permissionsByServerId,
    required Map<String, ServerSettings> serverSettingsByServerId,
    required Map<String, String> userIdByServerId,
    required Map<String, List<VoiceDeckState>> voiceDeckStatesByServerId,
    required Map<String, VoicePresenceState> localVoiceStateByServerId,
    String? activeServerId,
    String? currentUsername,
    String? selectedServerId,
    String? selectedChannelId,
  })  : _servers = servers,
        _channels = channels,
        _membersByServer = membersByServer,
        _messagesByChannel = messagesByChannel,
        _tokensByServerId = tokensByServerId,
        _rememberedUsersByServer = rememberedUsersByServer,
        _permissionsByServerId = permissionsByServerId,
        _serverSettingsByServerId = serverSettingsByServerId,
        _userIdByServerId = userIdByServerId,
        _voiceDeckStatesByServerId = voiceDeckStatesByServerId,
        _localVoiceStateByServerId = localVoiceStateByServerId,
        _activeServerId = activeServerId,
        _currentUsername = currentUsername,
        _selectedServerId = selectedServerId,
        _selectedChannelId = selectedChannelId {
    _micInput.addListener(_handleMicInputChanged);
    _voiceTransport.addListener(_handleVoiceTransportChanged);
    _voiceTransport.onLocalIceCandidate = _handleLocalVoiceIceCandidate;
  }

  factory AppState.empty() {
    return AppState._(
      servers: [],
      channels: [],
      membersByServer: {},
      messagesByChannel: {},
      tokensByServerId: {},
      rememberedUsersByServer: {},
      permissionsByServerId: {},
      serverSettingsByServerId: {},
      userIdByServerId: {},
      voiceDeckStatesByServerId: {},
      localVoiceStateByServerId: {},
    );
  }

  static Future<AppState> load() async {
    final prefs = await SharedPreferences.getInstance();
    await YappaAudioPreferences.load();
    await YappaVideoPreferences.load();

    final state = AppState.empty();
    state._restoreFromPrefs(prefs);

    final activeServerId = state._activeServerId;
    if (activeServerId != null &&
        state._tokensByServerId.containsKey(activeServerId)) {
      try {
        await state._restoreSession(
          activeServerId,
          reconnectRealtime: true,
          notify: false,
        );
      } catch (_) {
        state._tokensByServerId.remove(activeServerId);
        state._rememberedUsersByServer.remove(activeServerId);
        state._permissionsByServerId.remove(activeServerId);
        state._serverSettingsByServerId.remove(activeServerId);
        state._userIdByServerId.remove(activeServerId);
        state._voiceDeckStatesByServerId.remove(activeServerId);
        state._localVoiceStateByServerId.remove(activeServerId);
        state._activeServerId = null;
        state._currentUsername = null;
        await state._persist();
      }
    }

    return state;
  }

  bool get hasActiveSession =>
      _activeServerId != null &&
      _currentUsername != null &&
      _serverById(_activeServerId!) != null;

  bool get isBusy => _isBusy;
  String? get lastError => _lastError;
  String get currentUsername => _currentUsername ?? 'Offline';

  String get currentDisplayName {
    final member = currentUserMemberForSelectedServer;
    if (member != null && member.name.trim().isNotEmpty) {
      return member.name;
    }
    return _currentUsername ?? 'Offline';
  }

  String get currentYuid => _globalYuid ?? 'YUID unavailable';

  MicInputSnapshot get micInputSnapshot => _micInput.snapshot;
  bool get micPermissionGranted => _micInput.hasPermission;
  bool get micCaptureActive => _micInput.isCapturing;
  double get micInputLevel => _micInput.level;
  double get micInputPeak => _micInput.peak;
  String? get micInputError => _micInput.error;

  VoiceTransportSnapshot get voiceTransportSnapshot => _voiceTransport.snapshot;
  bool get voiceTransportInitialized => _voiceTransport.snapshot.initialized;
  bool get voiceTransportJoined => _voiceTransport.snapshot.joined;
  bool get voiceTransportJoining => _voiceTransport.snapshot.joining;
  bool get voiceTransportMicrophoneReady =>
      _voiceTransport.snapshot.microphoneReady;
  bool get voiceTransportRemoteAudioAttached =>
      _voiceTransport.snapshot.remoteAudioAttached;
  String? get voiceTransportError => _voiceTransport.snapshot.error;
  Map<String, VoiceTransportPeerState> get voiceTransportPeers =>
      _voiceTransport.snapshot.peers;

  livekit.VideoTrack? get localCameraTrack => _voiceTransport.localCameraTrack;
  livekit.VideoTrack? get localScreenShareTrack {
    if (_screenShareSelectionPending || !selectedLocalVoiceState.screenShareEnabled) {
      return null;
    }
    return _voiceTransport.localScreenShareTrack;
  }
  Map<String, livekit.VideoTrack> get remoteCameraTracks =>
      _voiceTransport.remoteCameraTracks;
  Map<String, livekit.VideoTrack> get remoteScreenShareTracks =>
      _voiceTransport.remoteScreenShareTracks;

  bool get voiceActivityEnabled => _voiceActivityEnabled;
  YappaVoiceInputMode get voiceInputMode => YappaAudioPreferences.voiceInputMode;
  String? get preferredOutputDeviceId =>
      YappaAudioPreferences.preferredOutputDeviceId;

  ServerPermissions permissionsForServer(String serverId) =>
      _permissionsByServerId[serverId] ?? const ServerPermissions();

  bool get canManageSelectedServer =>
      permissionsForServer(selectedServerId).canOpenAdminPanel;

  bool get isSelectedServerOwner =>
      permissionsForServer(selectedServerId).isOwner;

  ServerSettings? get selectedServerSettings =>
      _serverSettingsByServerId[selectedServerId];

  bool get isOnHome => selectedServerId.isEmpty;

  List<ChatServer> get servers => List.unmodifiable(_servers);

  String get selectedServerId {
    if (_selectedServerId != null &&
        _servers.any((server) => server.id == _selectedServerId)) {
      return _selectedServerId!;
    }
    return '';
  }

  String get selectedChannelId {
    final selected = _selectedChannelId;
    if (selected != null &&
        channelsForSelectedServer.any((channel) => channel.id == selected)) {
      return selected;
    }

    if (channelsForSelectedServer.isNotEmpty) {
      return channelsForSelectedServer.first.id;
    }

    return '';
  }

  ChatServer get selectedServer {
    return _serverById(selectedServerId) ??
        const ChatServer(
          id: 'no_server',
          name: 'No Server Selected',
          shortName: '--',
          tagline: 'Pick a node from the portal',
          description: 'Pick a node from the portal',
          address: '',
        );
  }

  List<ChatChannel> get channelsForSelectedServer {
    if (selectedServerId.isEmpty) {
      return const [];
    }

    final filtered = _channels
        .where((channel) => channel.serverId == selectedServerId)
        .toList()
      ..sort((a, b) {
        final comparePosition = a.position.compareTo(b.position);
        if (comparePosition != 0) return comparePosition;
        return a.name.compareTo(b.name);
      });

    return filtered;
  }

  ChatChannel get selectedChannel {
    final channels = channelsForSelectedServer;
    if (channels.isNotEmpty) {
      return channels.firstWhere(
        (channel) => channel.id == selectedChannelId,
        orElse: () => channels.first,
      );
    }

    return const ChatChannel(
      id: 'no_channel',
      serverId: 'no_server',
      name: 'general',
      type: ChannelType.text,
    );
  }

  List<ChatMessage> get selectedMessages => List.unmodifiable(
        _messagesByChannel[selectedChannelId] ?? const <ChatMessage>[],
      );

  List<Member> get selectedMembers => List.unmodifiable(
        _membersByServer[selectedServerId] ?? const <Member>[],
      );

  List<VoiceDeckState> get selectedVoiceDeckStates {
    final serverId = selectedServerId;
    if (serverId.isEmpty) {
      return const [];
    }

    final stored = List<VoiceDeckState>.from(
      _voiceDeckStatesByServerId[serverId] ?? const <VoiceDeckState>[],
    );

    final knownIds = stored.map((item) => item.channelId).toSet();

    for (final channel in channelsForSelectedServer
        .where((channel) => channel.type == ChannelType.voice)) {
      if (!knownIds.contains(channel.id)) {
        stored.add(
          VoiceDeckState(
            channelId: channel.id,
            channelName: channel.name,
            occupancy: 0,
            activeSince: null,
          ),
        );
      }
    }

    stored.sort((a, b) {
      final left = _channelById(a.channelId);
      final right = _channelById(b.channelId);
      final leftPosition = left?.position ?? 999999;
      final rightPosition = right?.position ?? 999999;
      final comparePosition = leftPosition.compareTo(rightPosition);
      if (comparePosition != 0) return comparePosition;
      return a.channelName.compareTo(b.channelName);
    });

    return List.unmodifiable(stored);
  }

  VoiceDeckState? voiceDeckStateForChannel(String channelId) {
    for (final state in selectedVoiceDeckStates) {
      if (state.channelId == channelId) {
        return state;
      }
    }
    return null;
  }

  String? get currentUserIdForSelectedServer =>
      _userIdByServerId[selectedServerId];

  Member? get currentUserMemberForSelectedServer {
    final members = _membersByServer[selectedServerId] ?? const <Member>[];
    final userId = _userIdByServerId[selectedServerId];

    if (userId != null) {
      for (final member in members) {
        if (member.id == userId) {
          return member;
        }
      }
    }

    final username = _currentUsername;
    if (username != null) {
      for (final member in members) {
        if (member.username == username || member.name == username) {
          return member;
        }
      }
    }

    return null;
  }

  double voiceMemberVolumeFor(String userId) {
    final stored = _voiceMemberVolumesByServerId[selectedServerId]?[userId];
    if (stored == null) {
      return 1.0;
    }
    return stored.clamp(0.0, 1.5).toDouble();
  }

  Future<void> setVoiceMemberVolume({
    required String userId,
    required double volume,
  }) async {
    final serverId = selectedServerId;
    if (serverId.isEmpty) {
      return;
    }

    final safeVolume = volume.clamp(0.0, 1.5).toDouble();
    final volumes = _voiceMemberVolumesByServerId.putIfAbsent(
      serverId,
      () => <String, double>{},
    );

    if ((safeVolume - 1.0).abs() < 0.001) {
      volumes.remove(userId);
      if (volumes.isEmpty) {
        _voiceMemberVolumesByServerId.remove(serverId);
      }
    } else {
      volumes[userId] = safeVolume;
    }

    try {
      await _voiceTransport.setPeerVolume(userId, safeVolume);
    } catch (_) {}

    notifyListeners();
    await _persist();
  }

  List<Member> _applyLocalProfilesToMembers(String serverId, List<Member> members) {
    return List<Member>.unmodifiable(members);
  }

  String? get currentVoiceChannelIdForSelectedServer =>
      currentUserMemberForSelectedServer?.voiceChannelId;

  DateTime? get currentVoiceJoinedAtForSelectedServer =>
      currentUserMemberForSelectedServer?.voiceJoinedAt;

  bool get isInVoiceDeckOnSelectedServer =>
      currentVoiceChannelIdForSelectedServer != null;

  bool isCurrentUserInVoiceDeck(String channelId) =>
      currentVoiceChannelIdForSelectedServer == channelId;

  List<Member> membersForVoiceDeck(String channelId) {
    final members = (_membersByServer[selectedServerId] ?? const <Member>[])
        .where((member) => member.voiceChannelId == channelId)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(members);
  }

  VoicePresenceState get selectedLocalVoiceState =>
      _localVoiceStateByServerId[selectedServerId] ??
      const VoicePresenceState.defaults();

  bool get selectedMicMuted => selectedLocalVoiceState.micMuted;
  bool get selectedAudioMuted => selectedLocalVoiceState.audioMuted;
  bool get selectedCameraEnabled =>
      selectedLocalVoiceState.cameraEnabled || localCameraTrack != null;
  bool get selectedScreenShareEnabled =>
      !_screenShareSelectionPending &&
      selectedLocalVoiceState.screenShareEnabled;

  bool get screenShareSelectionPending => _screenShareSelectionPending;
  bool get selectedSpeaking => selectedLocalVoiceState.speaking;

  String? rememberedUsernameForServer(String serverId) =>
      _rememberedUsersByServer[serverId];

  bool hasRememberedSession(String serverId) =>
      _tokensByServerId.containsKey(serverId);

  Future<void> goHome() async {
    _selectedServerId = null;
    _selectedChannelId = null;
    notifyListeners();
    await _persist();
  }

  Future<void> openServer(String serverId) async {
    await selectServer(serverId);
  }

  Future<void> resumeSavedSession(String serverId) async {
    if (!_tokensByServerId.containsKey(serverId)) {
      return;
    }

    try {
      await _restoreSession(serverId, reconnectRealtime: true);
    } catch (_) {
      _tokensByServerId.remove(serverId);
      _rememberedUsersByServer.remove(serverId);
      _permissionsByServerId.remove(serverId);
      _serverSettingsByServerId.remove(serverId);
      _userIdByServerId.remove(serverId);
      _voiceDeckStatesByServerId.remove(serverId);
      _localVoiceStateByServerId.remove(serverId);

      if (_activeServerId == serverId) {
        _disconnectRealtime();
        _activeServerId = null;
        _currentUsername = null;
      }

      notifyListeners();
      await _persist();
    }
  }

  Future<String?> authenticate({
    required String serverId,
    required String username,
    required String password,
  }) async {
    final server = _serverById(serverId);
    if (server == null) {
      return 'Select a server node first.';
    }

    final cleanedUsername = username.trim();
    final cleanedPassword = password.trim();

    if (cleanedUsername.isEmpty) {
      return 'Enter a username for this server.';
    }

    if (cleanedPassword.length < 6) {
      return 'Use a password with at least 6 characters.';
    }

    _setBusy(true);

    try {
      final challenge = await _api.fetchYuidChallenge(baseUrl: server.address);
      final proof = await _yuidIdentity.buildAuthProof(
        serverId: challenge.serverId,
        username: cleanedUsername,
        nonce: challenge.nonce,
      );
      _globalYuid = proof.yuid;

      final auth = await _api.authenticate(
        baseUrl: server.address,
        username: cleanedUsername,
        password: cleanedPassword,
        yuid: proof.yuid,
        yuidPublicKey: proof.publicKeyBase64Url,
        yuidSignature: proof.signatureBase64Url,
        yuidNonce: challenge.nonce,
      );

      _upsertServer(auth.server);
      _replaceChannelsForServer(auth.server.id, auth.channels);
      _permissionsByServerId[auth.server.id] = auth.permissions;
      _userIdByServerId[auth.server.id] = auth.user.id;
      _localVoiceStateByServerId[auth.server.id] = auth.user.voiceState;

      if (auth.permissions.isOwner) {
        try {
          _serverSettingsByServerId[auth.server.id] =
              await _api.fetchServerSettings(
            baseUrl: auth.server.address,
            token: auth.token,
          );
        } catch (_) {}
      } else {
        _serverSettingsByServerId.remove(auth.server.id);
      }

      _tokensByServerId[auth.server.id] = auth.token;
      _rememberedUsersByServer[auth.server.id] = auth.user.username;

      _activateSession(
        serverId: auth.server.id,
        username: auth.user.username,
        notify: false,
      );

      await _loadMembers(serverId: auth.server.id, token: auth.token);
      await _loadInitialMessagesForServer(auth.server.id, auth.token);
      _connectRealtime(auth.server.id, auth.token);

      _lastError = null;
      notifyListeners();
      await _persist();
      return null;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      return error.message;
    } catch (_) {
      const message = 'Could not sign in to that node.';
      _lastError = message;
      notifyListeners();
      return message;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> selectServer(String serverId) async {
    _selectedServerId = serverId;
    _selectedChannelId = _firstChannelIdForServer(serverId);

    final token = _tokensByServerId[serverId];
    if (token == null) {
      _disconnectRealtime();
      _activeServerId = null;
      _currentUsername = null;
      notifyListeners();
      await _persist();
      return;
    }

    try {
      await _restoreSession(serverId, reconnectRealtime: true);
    } catch (_) {
      _tokensByServerId.remove(serverId);
      _rememberedUsersByServer.remove(serverId);
      _permissionsByServerId.remove(serverId);
      _serverSettingsByServerId.remove(serverId);
      _userIdByServerId.remove(serverId);
      _voiceDeckStatesByServerId.remove(serverId);
      _localVoiceStateByServerId.remove(serverId);
      _disconnectRealtime();
      _activeServerId = null;
      _currentUsername = null;
      notifyListeners();
      await _persist();
    }
  }

  Future<void> selectChannel(String channelId) async {
    _selectedChannelId = channelId;
    notifyListeners();

    try {
      await _loadSelectedChannelMessages();
    } catch (_) {}

    await _persist();
  }

  Future<void> joinVoiceDeck(String channelId) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final channel = _channelById(channelId);
    if (channel == null || channel.type != ChannelType.voice) {
      throw Exception('That voice deck does not exist.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    _setBusy(true);

    try {
      final result = await realtime.joinVoiceDeck(channelId);
      _applyLocalVoicePresence(
        serverId: selectedServerId,
        voiceChannelId: result.channelId,
        voiceJoinedAt: result.joinedAt,
      );
      await startMicInputCapture();
      await _startVoiceTransportForCurrentDeck(
        channelId: result.channelId,
      );
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> leaveVoiceDeck() async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    _setBusy(true);

    try {
      await realtime.leaveVoiceDeck();
      _applyLocalVoicePresence(
        serverId: selectedServerId,
        voiceChannelId: null,
        voiceJoinedAt: null,
      );
      _localVoiceStateByServerId[selectedServerId] =
          selectedLocalVoiceState.copyWith(
        cameraEnabled: false,
        screenShareEnabled: false,
        speaking: false,
      );
      _voiceActivityReleaseTimer?.cancel();
      _voiceActivityPttOverride = false;
      _voiceOfferInFlightPeerIds.clear();
      await _stopVoiceTransport();
      await stopMicInputCapture();
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<VoicePresenceState> updateSelectedVoiceState({
    bool? micMuted,
    bool? audioMuted,
    bool? cameraEnabled,
    bool? screenShareEnabled,
    bool? speaking,
  }) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    final serverId = selectedServerId;
    final current = selectedLocalVoiceState;
    var resolvedMicMuted = micMuted ?? current.micMuted;
    var resolvedAudioMuted = audioMuted ?? current.audioMuted;

    if (audioMuted != null) {
      if (audioMuted) {
        final autoMutedMic = !current.micMuted;
        _audioMuteAutoMutedMicByServerId[serverId] = autoMutedMic;
        resolvedMicMuted = true;
      } else {
        final shouldRestoreMic =
            _audioMuteAutoMutedMicByServerId.remove(serverId) == true;
        if (micMuted == null && shouldRestoreMic) {
          resolvedMicMuted = false;
        }
      }
    }

    if (micMuted != null && !micMuted && resolvedAudioMuted) {
      resolvedAudioMuted = false;
      _audioMuteAutoMutedMicByServerId.remove(serverId);
    }

    final next = await realtime.updateVoiceState(
      micMuted: resolvedMicMuted,
      audioMuted: resolvedAudioMuted,
      cameraEnabled: cameraEnabled,
      screenShareEnabled: screenShareEnabled,
      speaking: speaking,
    );

    _localVoiceStateByServerId[serverId] = next;

    if (micMuted != null || audioMuted != null || speaking != null) {
      _scheduleTransportMuteSync(force: true);
    }

    try {
      await _voiceTransport.setOutputMuted(next.audioMuted);
    } catch (_) {}

    notifyListeners();
    return next;
  }

  Future<VoicePresenceState> setSelectedCameraEnabled(bool enabled) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    await _voiceTransport.setCameraEnabled(enabled);

    try {
      final next = await realtime.updateVoiceState(cameraEnabled: enabled);
      _localVoiceStateByServerId[selectedServerId] = next;
      notifyListeners();
      return next;
    } catch (error) {
      try {
        await _voiceTransport.setCameraEnabled(!enabled);
      } catch (_) {}
      rethrow;
    }
  }

  Future<VoicePresenceState?> setSelectedScreenShareEnabled(
    bool enabled, {
    VoiceScreenShareTarget preferredTarget = VoiceScreenShareTarget.any,
  }) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    if (enabled) {
      final blockMessage = YappaVideoPreferences.linuxScreenShareBlockMessage();
      if (blockMessage != null) {
        throw Exception(blockMessage);
      }

      if (!_screenShareSelectionPending) {
        _screenShareSelectionPending = true;
        notifyListeners();
      }
    }

    try {
      final started = await _voiceTransport.setScreenShareEnabled(
        enabled,
        preferredTarget: preferredTarget,
      );

      if (!started) {
        if (_screenShareSelectionPending) {
          _screenShareSelectionPending = false;
          notifyListeners();
        }
        return null;
      }

      final next = await realtime.updateVoiceState(screenShareEnabled: enabled);
      _localVoiceStateByServerId[selectedServerId] = next;

      if (_screenShareSelectionPending) {
        _screenShareSelectionPending = false;
      }

      notifyListeners();
      return next;
    } catch (error) {
      if (_screenShareSelectionPending) {
        _screenShareSelectionPending = false;
        notifyListeners();
      }

      if (enabled) {
        try {
          await _voiceTransport.setScreenShareEnabled(
            false,
            preferredTarget: preferredTarget,
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<VoicePresenceState> updateSelectedSpeaking(bool speaking) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final realtime = _realtime;
    if (realtime == null) {
      throw Exception('Realtime connection is not active.');
    }

    _voiceActivityPttOverride = speaking;
    if (speaking) {
      _voiceActivityReleaseTimer?.cancel();
    }
    _scheduleTransportMuteSync(force: true);

    final next = await realtime.setSpeaking(speaking);
    _localVoiceStateByServerId[selectedServerId] = next;
    notifyListeners();
    return next;
  }

  Future<bool> ensureMicInputPermission() async {
    final granted = await _micInput.ensurePermission();
    notifyListeners();
    return granted;
  }

  Future<void> startMicInputCapture() async {
    await _micInput.startCapture();
    notifyListeners();
  }

  Future<void> stopMicInputCapture() async {
    await _micInput.stopCapture();
    notifyListeners();
  }

  Future<void> refreshVoiceAudioPreferences() async {
    await _voiceTransport.refreshAudioPreferences();
    _scheduleTransportMuteSync(force: true);
    notifyListeners();
  }

  Future<ChatAttachment> uploadAttachmentFile(File file) async {
    if (!hasActiveSession) {
      throw Exception('No active session.');
    }

    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];
    final channel = _channelById(selectedChannelId);

    if (server == null || token == null || channel == null) {
      throw Exception('No active text channel selected.');
    }

    if (channel.type != ChannelType.text) {
      throw Exception('Files can only be uploaded in text channels.');
    }

    _setBusy(true);

    try {
      final attachment = await _api.uploadAttachment(
        baseUrl: server.address,
        token: token,
        channelId: channel.id,
        file: file,
      );

      _lastError = null;
      return attachment;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } catch (error) {
      _lastError = error.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }


  Future<LinkPreview?> fetchLinkPreviewForSelectedServer(String url) {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      return Future<LinkPreview?>.value(null);
    }

    final normalizedUrl = url.trim();
    if (normalizedUrl.isEmpty) {
      return Future<LinkPreview?>.value(null);
    }

    final cacheKey = '${server.id}::$normalizedUrl';
    return _linkPreviewCache.putIfAbsent(cacheKey, () async {
      try {
        return await _api.fetchLinkPreview(
          baseUrl: server.address,
          token: token,
          url: normalizedUrl,
        );
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> sendMessage(
    String content, {
    List<String> attachmentIds = const [],
  }) async {
    final text = content.trim();
    if ((text.isEmpty && attachmentIds.isEmpty) || !hasActiveSession) {
      return;
    }

    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];
    final channel = _channelById(selectedChannelId);

    if (server == null || token == null || channel == null) {
      return;
    }

    if (channel.type != ChannelType.text) {
      return;
    }

    try {
      final message = await _api.sendMessage(
        baseUrl: server.address,
        token: token,
        channelId: channel.id,
        content: text,
        attachmentIds: attachmentIds,
      );

      _upsertMessage(message);
      _lastError = null;
      notifyListeners();
      await _persist();
    } catch (error) {
      _lastError = error.toString();
      notifyListeners();
    }
  }

  Future<ServerSettings?> ensureSelectedServerSettingsLoaded() async {
    if (!canManageSelectedServer) {
      return null;
    }

    final cached = _serverSettingsByServerId[selectedServerId];
    if (cached != null) {
      return cached;
    }

    return refreshSelectedServerSettings();
  }

  Future<ServerSettings> refreshSelectedServerSettings() async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      throw Exception('No active owner session for this node.');
    }

    if (!canManageSelectedServer) {
      throw Exception('Only the node owner can open these controls.');
    }

    _setBusy(true);

    try {
      final settings = await _api.fetchServerSettings(
        baseUrl: server.address,
        token: token,
      );
      _serverSettingsByServerId[server.id] = settings;
      _lastError = null;
      notifyListeners();
      return settings;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<ChatServer> updateSelectedServerProfile({
    required String name,
    required String description,
    String? accentColor,
    String? iconUrl,
    String? bannerUrl,
  }) async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      throw Exception('No active owner session for this node.');
    }

    if (!canManageSelectedServer) {
      throw Exception('Only the node owner can change server details.');
    }

    _setBusy(true);

    try {
      final branding = <String, dynamic>{
        'iconUrl': iconUrl,
        'bannerUrl': bannerUrl,
      };

      if (accentColor != null) {
        branding['accentColor'] = accentColor;
      }

      final updatedServer = await _api.updateServerProfile(
        baseUrl: server.address,
        token: token,
        patch: {
          'name': name,
          'description': description,
          'branding': branding,
        },
      );

      _upsertServer(updatedServer);
      _lastError = null;
      notifyListeners();
      await _persist();
      return updatedServer;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<ChatServer> uploadSelectedServerBrandingAsset({
    required String slot,
    required File file,
  }) async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      throw Exception('No active owner session for this node.');
    }

    if (!canManageSelectedServer) {
      throw Exception('Only the node owner can upload branding assets.');
    }

    _setBusy(true);

    try {
      final result = await _api.uploadServerBrandingAsset(
        baseUrl: server.address,
        token: token,
        slot: slot,
        file: file,
      );

      _upsertServer(result.server);
      _lastError = null;
      notifyListeners();
      await _persist();
      return result.server;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<ServerSettings> updateSelectedServerSettings({
    required Map<String, dynamic> patch,
  }) async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      throw Exception('No active owner session for this node.');
    }

    if (!canManageSelectedServer) {
      throw Exception('Only the node owner can change media settings.');
    }

    _setBusy(true);

    try {
      final settings = await _api.updateServerSettings(
        baseUrl: server.address,
        token: token,
        patch: patch,
      );
      _serverSettingsByServerId[server.id] = settings;
      _lastError = null;
      notifyListeners();
      return settings;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<List<ChatChannel>> createChannelOnSelectedServer({
    required String name,
    required ChannelType type,
  }) async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (server == null || token == null) {
      throw Exception('No active owner session for this node.');
    }

    if (!canManageSelectedServer) {
      throw Exception('Only the node owner can create channels.');
    }

    _setBusy(true);

    try {
      final result = await _api.createChannel(
        baseUrl: server.address,
        token: token,
        name: name,
        type: type.name,
      );

      _replaceChannelsForServer(server.id, result.channels);
      _selectedChannelId = result.channel.id;
      _lastError = null;
      notifyListeners();
      await _persist();
      return result.channels;
    } on ApiException catch (error) {
      _lastError = error.message;
      notifyListeners();
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> forgetCurrentServerSession() async {
    final serverId = _activeServerId ??
        (_selectedServerId != null && _selectedServerId!.isNotEmpty
            ? _selectedServerId
            : null);

    if (serverId == null) {
      return;
    }

    final server = _serverById(serverId);
    final token = _tokensByServerId[serverId];

    if (server != null && token != null) {
      try {
        await _api.logout(baseUrl: server.address, token: token);
      } catch (_) {}
    }

    _tokensByServerId.remove(serverId);
    _rememberedUsersByServer.remove(serverId);
    _permissionsByServerId.remove(serverId);
    _serverSettingsByServerId.remove(serverId);
    _userIdByServerId.remove(serverId);
    _voiceDeckStatesByServerId.remove(serverId);
    _localVoiceStateByServerId.remove(serverId);

    if (_activeServerId == serverId) {
      _disconnectRealtime();
      _voiceOfferInFlightPeerIds.clear();
      _activeServerId = null;
      _currentUsername = null;
    }

    notifyListeners();
    await _persist();
  }

  Future<void> addServerNode({
    required String address,
    String? name,
  }) async {
    _setBusy(true);

    try {
      final result = await _api.handshake(address);

      final server = result.server;

      _upsertServer(server);
      _replaceChannelsForServer(server.id, result.channels);
      _localVoiceStateByServerId.putIfAbsent(
        server.id,
        () => const VoicePresenceState.defaults(),
      );

      _selectedServerId = server.id;
      _selectedChannelId = _firstChannelIdForServer(server.id);

      final token = _tokensByServerId[server.id];
      if (token != null) {
        await _restoreSession(server.id, reconnectRealtime: true);
      } else {
        _disconnectRealtime();
        _activeServerId = null;
        _currentUsername = null;
      }

      _lastError = null;
      notifyListeners();
      await _persist();
    } on ApiException catch (error) {
      throw Exception(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> removeServerNode(String serverId) async {
    final server = _serverById(serverId);
    final token = _tokensByServerId[serverId];

    if (server != null && token != null) {
      try {
        await _api.logout(baseUrl: server.address, token: token);
      } catch (_) {}
    }

    final removedChannelIds = _channels
        .where((channel) => channel.serverId == serverId)
        .map((channel) => channel.id)
        .toList();

    _servers.removeWhere((server) => server.id == serverId);
    _channels.removeWhere((channel) => channel.serverId == serverId);

    for (final channelId in removedChannelIds) {
      _messagesByChannel.remove(channelId);
    }

    _membersByServer.remove(serverId);
    _tokensByServerId.remove(serverId);
    _rememberedUsersByServer.remove(serverId);
    _permissionsByServerId.remove(serverId);
    _serverSettingsByServerId.remove(serverId);
    _userIdByServerId.remove(serverId);
    _voiceDeckStatesByServerId.remove(serverId);
    _localVoiceStateByServerId.remove(serverId);

    if (_activeServerId == serverId) {
      _disconnectRealtime();
      _voiceOfferInFlightPeerIds.clear();
      _activeServerId = null;
      _currentUsername = null;
    }

    if (_selectedServerId == serverId) {
      _selectedServerId = null;
      _selectedChannelId = null;
    } else if (_selectedChannelId != null &&
        removedChannelIds.contains(_selectedChannelId)) {
      _selectedChannelId = _selectedServerId == null
          ? null
          : _firstChannelIdForServer(_selectedServerId!);
    }

    notifyListeners();
    await _persist();
  }

  @override
  void dispose() {
    _voiceActivityReleaseTimer?.cancel();
    _disconnectRealtime();
    _micInput.removeListener(_handleMicInputChanged);
    _voiceTransport.removeListener(_handleVoiceTransportChanged);
    _micInput.dispose();
    _voiceTransport.dispose();
    super.dispose();
  }

  Future<void> _restoreSession(
    String serverId, {
    required bool reconnectRealtime,
    bool notify = true,
  }) async {
    final server = _serverById(serverId);
    final token = _tokensByServerId[serverId];

    if (server == null || token == null) {
      throw Exception('Missing saved session.');
    }

    final me = await _api.fetchMe(
      baseUrl: server.address,
      token: token,
    );

    _upsertServer(me.server);
    _replaceChannelsForServer(me.server.id, me.channels);
    _rememberedUsersByServer[me.server.id] = me.user.username;
    _permissionsByServerId[me.server.id] = me.permissions;
    _userIdByServerId[me.server.id] = me.user.id;
    _localVoiceStateByServerId[me.server.id] = me.user.voiceState;

    if (me.permissions.isOwner) {
      try {
        _serverSettingsByServerId[me.server.id] =
            await _api.fetchServerSettings(
          baseUrl: me.server.address,
          token: token,
        );
      } catch (_) {}
    } else {
      _serverSettingsByServerId.remove(me.server.id);
    }

    _activateSession(
      serverId: me.server.id,
      username: me.user.username,
      notify: false,
    );

    await _loadMembers(serverId: me.server.id, token: token);
    await _loadInitialMessagesForServer(me.server.id, token);

    if (reconnectRealtime) {
      _connectRealtime(me.server.id, token);
    }

    _lastError = null;

    if (notify) {
      notifyListeners();
    }

    await _persist();
  }

  Future<String?> updateCurrentUserProfile({
    required String displayName,
    String? avatarSource,
    bool updateAvatar = false,
  }) async {
    final serverId = selectedServerId;
    final server = _serverById(serverId);
    final token = _tokensByServerId[serverId];
    final username = _currentUsername;
    if (serverId.isEmpty || server == null || token == null || username == null) {
      return 'Sign in before editing your profile.';
    }

    final cleaned = displayName.trim();
    if (cleaned.length < 2 || cleaned.length > 32) {
      return 'Display name must be 2-32 characters.';
    }

    try {
      final updatedUser = await _api.updateCurrentUserSettings(
        baseUrl: server.address,
        token: token,
        displayName: cleaned,
        avatarUrl: updateAvatar
            ? (avatarSource == null || avatarSource.trim().isEmpty
                ? null
                : avatarSource)
            : ApiClient.avatarUnspecified,
      );

      final members = List<Member>.from(_membersByServer[serverId] ?? const <Member>[]);
      final userId = _userIdByServerId[serverId];
      var replaced = false;
      for (var i = 0; i < members.length; i++) {
        final member = members[i];
        if ((userId != null && member.id == userId) || member.username == username) {
          members[i] = updatedUser;
          replaced = true;
        }
      }
      if (!replaced) {
        members.add(updatedUser);
      }
      _membersByServer[serverId] = members;
      notifyListeners();
      await _persist();
      return null;
    } on ApiException catch (error) {
      return error.message;
    } catch (_) {
      return 'Could not update your profile right now.';
    }
  }

  Future<String?> updateCurrentUserAvatar({
    String? avatarSource,
  }) async {
    final serverId = selectedServerId;
    final server = _serverById(serverId);
    final token = _tokensByServerId[serverId];
    final username = _currentUsername;
    if (serverId.isEmpty || server == null || token == null || username == null) {
      return 'Sign in before editing your profile.';
    }

    try {
      final updatedUser = await _api.updateCurrentUserSettings(
        baseUrl: server.address,
        token: token,
        avatarUrl: avatarSource == null || avatarSource.trim().isEmpty ? null : avatarSource,
      );

      final members = List<Member>.from(_membersByServer[serverId] ?? const <Member>[]);
      final userId = _userIdByServerId[serverId];
      var replaced = false;
      for (var i = 0; i < members.length; i++) {
        final member = members[i];
        if ((userId != null && member.id == userId) || member.username == username) {
          members[i] = updatedUser;
          replaced = true;
        }
      }
      if (!replaced) {
        members.add(updatedUser);
      }
      _membersByServer[serverId] = members;
      notifyListeners();
      await _persist();
      return null;
    } on ApiException catch (error) {
      return error.message;
    } catch (_) {
      return 'Could not update your profile picture right now.';
    }
  }

  Future<void> _loadMembers({
    required String serverId,
    required String token,
  }) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final members = await _api.fetchMembers(
      baseUrl: server.address,
      token: token,
    );

    _membersByServer[serverId] = _applyLocalProfilesToMembers(serverId, members);
  }

  Future<void> _loadInitialMessagesForServer(
    String serverId,
    String token,
  ) async {
    final server = _serverById(serverId);
    if (server == null) return;

    final channels = _channelsForServer(serverId)
        .where((channel) => channel.type == ChannelType.text)
        .toList();

    if (channels.isEmpty) {
      return;
    }

    final targetChannelId = (_selectedServerId == serverId &&
            _selectedChannelId != null &&
            _selectedChannelId!.isNotEmpty)
        ? _selectedChannelId!
        : channels.first.id;

    final targetChannel = _channelById(targetChannelId);
    if (targetChannel == null || targetChannel.type != ChannelType.text) {
      return;
    }

    final messages = await _api.fetchMessages(
      baseUrl: server.address,
      token: token,
      channelId: targetChannel.id,
    );

    _messagesByChannel[targetChannel.id] = messages;
  }

  Future<void> _loadSelectedChannelMessages() async {
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];
    final channel = _channelById(selectedChannelId);

    if (server == null || token == null || channel == null) {
      return;
    }

    if (channel.type != ChannelType.text) {
      return;
    }

    final messages = await _api.fetchMessages(
      baseUrl: server.address,
      token: token,
      channelId: channel.id,
    );

    _messagesByChannel[channel.id] = messages;
    notifyListeners();
  }

  void _connectRealtime(String serverId, String token) {
    final server = _serverById(serverId);
    if (server == null) {
      return;
    }

    _disconnectRealtime();

    _realtime = RealtimeClient(
      onHello: (server, channels, members, voice, meVoiceState) {
        _upsertServer(server);
        _replaceChannelsForServer(server.id, channels);
        _membersByServer[server.id] = _applyLocalProfilesToMembers(server.id, members);
        _voiceDeckStatesByServerId[server.id] = voice;
        _localVoiceStateByServerId[server.id] = meVoiceState;

        if (_selectedServerId == server.id &&
            !_channelsForServer(server.id)
                .any((channel) => channel.id == _selectedChannelId)) {
          _selectedChannelId = _firstChannelIdForServer(server.id);
        }

        notifyListeners();
        _persist();
      },
      onPresenceUpdate: (members, voice) {
        _membersByServer[serverId] = _applyLocalProfilesToMembers(serverId, members);
        _voiceDeckStatesByServerId[serverId] = voice;
        notifyListeners();
        _persist();
      },
      onMessage: (message) {
        _upsertMessage(message);
        notifyListeners();
        _persist();
      },
      onServerUpdated: (server, channels, voice) {
        _upsertServer(server);
        _replaceChannelsForServer(server.id, channels);
        _voiceDeckStatesByServerId[server.id] = voice;

        if (_selectedServerId == server.id &&
            !_channelsForServer(server.id)
                .any((channel) => channel.id == _selectedChannelId)) {
          _selectedChannelId = _firstChannelIdForServer(server.id);
        }

        notifyListeners();
        _persist();
      },
      onError: (message) {
        _lastError = message;
        notifyListeners();
      },
    );

    _realtime!.connect(server: server, token: token);
  }

  void _disconnectRealtime() {
    _realtime?.dispose();
    _realtime = null;
  }

  void _activateSession({
    required String serverId,
    required String username,
    bool notify = true,
  }) {
    _activeServerId = serverId;
    _currentUsername = username;
    _selectedServerId = serverId;

    if (_selectedChannelId == null ||
        !_channelsForServer(serverId)
            .any((channel) => channel.id == _selectedChannelId)) {
      _selectedChannelId = _firstChannelIdForServer(serverId);
    }

    if (notify) {
      notifyListeners();
    }
  }

  void _applyLocalVoicePresence({
    required String serverId,
    required String? voiceChannelId,
    required DateTime? voiceJoinedAt,
  }) {
    final members = List<Member>.from(
      _membersByServer[serverId] ?? const <Member>[],
    );
    final currentUserId = _userIdByServerId[serverId];
    final currentUsername =
        _rememberedUsersByServer[serverId] ?? _currentUsername;

    int index = -1;
    if (currentUserId != null) {
      index = members.indexWhere((member) => member.id == currentUserId);
    }
    if (index == -1 && currentUsername != null) {
      index = members.indexWhere(
        (member) =>
            member.username == currentUsername || member.name == currentUsername,
      );
    }

    String? previousVoiceChannelId;
    if (index != -1) {
      previousVoiceChannelId = members[index].voiceChannelId;
      members[index] = members[index].copyWith(
        status: voiceChannelId == null
            ? (members[index].isOnline ? 'online' : 'offline')
            : 'voice_connected',
        voiceChannelId: voiceChannelId,
        voiceJoinedAt: voiceJoinedAt,
        clearVoiceChannelId: voiceChannelId == null,
        clearVoiceJoinedAt: voiceJoinedAt == null,
      );
      _membersByServer[serverId] = _applyLocalProfilesToMembers(serverId, members);
    }

    final states = List<VoiceDeckState>.from(
      _voiceDeckStatesByServerId[serverId] ?? const <VoiceDeckState>[],
    );

    if (previousVoiceChannelId != null &&
        previousVoiceChannelId != voiceChannelId) {
      final oldIndex = states.indexWhere(
        (state) => state.channelId == previousVoiceChannelId,
      );
      if (oldIndex != -1) {
        final oldState = states[oldIndex];
        final nextOccupancy =
            oldState.occupancy > 0 ? oldState.occupancy - 1 : 0;
        states[oldIndex] = VoiceDeckState(
          channelId: oldState.channelId,
          channelName: oldState.channelName,
          occupancy: nextOccupancy,
          activeSince: nextOccupancy == 0 ? null : oldState.activeSince,
        );
      }
    }

    if (voiceChannelId != null) {
      final newIndex =
          states.indexWhere((state) => state.channelId == voiceChannelId);
      if (newIndex != -1) {
        final current = states[newIndex];
        final nextOccupancy =
            current.channelId == previousVoiceChannelId &&
                    previousVoiceChannelId != null
                ? current.occupancy
                : current.occupancy + 1;

        states[newIndex] = VoiceDeckState(
          channelId: current.channelId,
          channelName: current.channelName,
          occupancy: nextOccupancy,
          activeSince: current.activeSince ?? voiceJoinedAt,
        );
      } else {
        final channel = _channelById(voiceChannelId);
        states.add(
          VoiceDeckState(
            channelId: voiceChannelId,
            channelName: channel?.name ?? 'Voice Deck',
            occupancy: 1,
            activeSince: voiceJoinedAt,
          ),
        );
      }
    }

    _voiceDeckStatesByServerId[serverId] = states;
  }

  Future<void> _startVoiceTransportForCurrentDeck({
    required String channelId,
  }) async {
    final userId = currentUserIdForSelectedServer;
    final server = _serverById(selectedServerId);
    final token = _tokensByServerId[selectedServerId];

    if (userId == null || userId.isEmpty || server == null || token == null) {
      return;
    }

    final credentials = await _api.fetchVoiceConnection(
      baseUrl: server.address,
      token: token,
      channelId: channelId,
    );

    await _voiceTransport.joinVoiceChannel(
      localPeerId: userId,
      voiceChannelId: channelId,
      serverUrl: credentials.serverUrl,
      participantToken: credentials.participantToken,
      roomName: credentials.roomName,
    );

    await _applyStoredVoiceMemberVolumesToTransport();
    _scheduleTransportMuteSync(force: true);
  }

  Future<void> _applyStoredVoiceMemberVolumesToTransport() async {
    final volumes = _voiceMemberVolumesByServerId[selectedServerId];
    await _voiceTransport.replacePeerVolumes(
      volumes ?? const <String, double>{},
    );
  }

  Future<void> _stopVoiceTransport() async {
    await _voiceTransport.leaveVoiceChannel();
  }

  void _handleMicInputChanged() {
    _syncVoiceActivityFromMic();
    notifyListeners();
  }

  void _handleVoiceTransportChanged() {
    _syncVoiceActivityFromMic();
    notifyListeners();
  }

  Future<void> _handleLocalVoiceIceCandidate(
    String peerId,
    RTCIceCandidate candidate,
  ) async {
    final realtime = _realtime;
    final channelId = _voiceTransport.voiceChannelId;
    if (realtime == null || channelId == null) return;

    final raw = candidate.candidate;
    if (raw == null || raw.trim().isEmpty) return;

    try {
      await realtime.sendVoiceIceCandidate(
        toUserId: peerId,
        channelId: channelId,
        candidate: raw,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      );
    } catch (error) {
      _lastError = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  void _syncVoiceActivityFromMic() {
    if (!_voiceActivityEnabled) return;
    if (!hasActiveSession) return;
    if (!isInVoiceDeckOnSelectedServer) return;

    final mode = YappaAudioPreferences.voiceInputMode;

    if (selectedMicMuted) {
      _scheduleVoiceActivityStop(immediate: true);
      return;
    }

    if (mode == YappaVoiceInputMode.pushToTalk) {
      if (_voiceActivityPttOverride) {
        _voiceActivityReleaseTimer?.cancel();
        _setSelectedSpeakingSilently(true);
      } else {
        _scheduleVoiceActivityStop(immediate: true);
      }
      return;
    }

    if (mode == YappaVoiceInputMode.alwaysOn) {
      _voiceActivityReleaseTimer?.cancel();
      _setSelectedSpeakingSilently(true);
      return;
    }

    if (_voiceActivityPttOverride) return;

    if (!_micInput.isCapturing) {
      _scheduleVoiceActivityStop();
      return;
    }

    final level = _micInput.level;
    final currentlySpeaking = selectedSpeaking;

    final startThreshold = YappaAudioPreferences.automaticSensitivity
        ? _defaultVoiceActivityStartThreshold
        : YappaAudioPreferences.manualSensitivity.clamp(0.0, 0.95);

    final stopThreshold = YappaAudioPreferences.automaticSensitivity
        ? _defaultVoiceActivityStopThreshold
        : (startThreshold - 0.04).clamp(0.0, startThreshold);

    if (!currentlySpeaking && level >= startThreshold) {
      _voiceActivityReleaseTimer?.cancel();
      _setSelectedSpeakingSilently(true);
      return;
    }

    if (currentlySpeaking && level <= stopThreshold) {
      _scheduleVoiceActivityStop();
      return;
    }

    if (currentlySpeaking && level > stopThreshold) {
      _voiceActivityReleaseTimer?.cancel();
    }
  }

  void _scheduleVoiceActivityStop({bool immediate = false}) {
    if (immediate) {
      _voiceActivityReleaseTimer?.cancel();
      _voiceActivityReleaseTimer = null;
      _setSelectedSpeakingSilently(false);
      return;
    }

    if (_voiceActivityReleaseTimer?.isActive == true) {
      return;
    }

    _voiceActivityReleaseTimer = Timer(_voiceActivityReleaseDelay, () {
      _voiceActivityReleaseTimer = null;
      _setSelectedSpeakingSilently(false);
    });
  }

  void _setSelectedSpeakingSilently(bool speaking) {
    if (!hasActiveSession) return;

    final serverId = selectedServerId;
    final current = _localVoiceStateByServerId[serverId] ??
        const VoicePresenceState.defaults();

    if (current.speaking == speaking) return;

    _localVoiceStateByServerId[serverId] = current.copyWith(speaking: speaking);
    _scheduleTransportMuteSync(force: true);
    notifyListeners();

    final realtime = _realtime;
    if (realtime == null) return;

    realtime.setSpeaking(speaking).then((next) {
      _localVoiceStateByServerId[serverId] = next;
      notifyListeners();
    }).catchError((_) {});
  }

  bool _desiredTransportMuted() {
    if (!_voiceTransport.joined) {
      return true;
    }

    if (!hasActiveSession || !isInVoiceDeckOnSelectedServer) {
      return true;
    }

    if (selectedMicMuted) {
      return true;
    }

    switch (YappaAudioPreferences.voiceInputMode) {
      case YappaVoiceInputMode.alwaysOn:
        return false;
      case YappaVoiceInputMode.pushToTalk:
        return !_voiceActivityPttOverride;
      case YappaVoiceInputMode.voiceActivityDetection:
        return !selectedSpeaking;
    }
  }

  void _scheduleTransportMuteSync({bool force = false}) {
    unawaited(_syncTransportMuteFromVoiceState(force: force));
  }

  Future<void> _syncTransportMuteFromVoiceState({bool force = false}) async {
    if (_voiceTransportMuteSyncRunning) {
      _voiceTransportMuteSyncQueued = true;
      if (force) {
        _lastAppliedTransportMuted = null;
      }
      return;
    }

    if (force) {
      _lastAppliedTransportMuted = null;
    }

    _voiceTransportMuteSyncRunning = true;
    try {
      do {
        _voiceTransportMuteSyncQueued = false;

        final shouldMute = _desiredTransportMuted();
        if (_lastAppliedTransportMuted == shouldMute) {
          continue;
        }

        await _voiceTransport.setMuted(shouldMute);
        _lastAppliedTransportMuted = shouldMute;
      } while (_voiceTransportMuteSyncQueued);
    } finally {
      _voiceTransportMuteSyncRunning = false;
    }
  }

  ChatServer? _serverById(String? serverId) {
    if (serverId == null || serverId.isEmpty) {
      return null;
    }

    for (final server in _servers) {
      if (server.id == serverId) {
        return server;
      }
    }

    return null;
  }

  ChatChannel? _channelById(String? channelId) {
    if (channelId == null || channelId.isEmpty) {
      return null;
    }

    for (final channel in _channels) {
      if (channel.id == channelId) {
        return channel;
      }
    }

    return null;
  }

  List<ChatChannel> _channelsForServer(String serverId) {
    return _channels.where((channel) => channel.serverId == serverId).toList();
  }

  String _firstChannelIdForServer(String serverId) {
    final channels = _channelsForServer(serverId)
      ..sort((a, b) {
        final comparePosition = a.position.compareTo(b.position);
        if (comparePosition != 0) return comparePosition;
        return a.name.compareTo(b.name);
      });

    if (channels.isNotEmpty) {
      return channels.first.id;
    }

    return '';
  }

  void _upsertServer(ChatServer server) {
    final index = _servers.indexWhere((existing) => existing.id == server.id);
    if (index == -1) {
      _servers.add(server);
    } else {
      final existing = _servers[index];
      _servers[index] = server.copyWith(
        address: server.address.trim().isEmpty
            ? existing.address
            : server.address,
        accentColor: server.accentColor.trim().isEmpty
            ? existing.accentColor
            : server.accentColor,
        iconUrl: server.iconUrl ?? existing.iconUrl,
        bannerUrl: server.bannerUrl ?? existing.bannerUrl,
      );
    }

    _servers.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  void _replaceChannelsForServer(String serverId, List<ChatChannel> channels) {
    _channels.removeWhere((channel) => channel.serverId == serverId);
    _channels.addAll(channels);

    _channels.sort((a, b) {
      final compareServer = a.serverId.compareTo(b.serverId);
      if (compareServer != 0) return compareServer;

      final comparePosition = a.position.compareTo(b.position);
      if (comparePosition != 0) return comparePosition;

      return a.name.compareTo(b.name);
    });
  }

  void _upsertMessage(ChatMessage message) {
    final list = _messagesByChannel.putIfAbsent(message.channelId, () => []);
    final index = list.indexWhere((existing) => existing.id == message.id);

    if (index == -1) {
      list.add(message);
    } else {
      list[index] = message;
    }

    list.sort((a, b) => a.sentAt.compareTo(b.sentAt));
  }

  void _setBusy(bool value) {
    _isBusy = value;
    notifyListeners();
  }

  void _restoreFromPrefs(SharedPreferences prefs) {
    _decodeServers(prefs.getString(_serversKey));
    _decodeChannels(prefs.getString(_channelsKey));
    _decodeMembers(prefs.getString(_membersKey));
    _decodeMessages(prefs.getString(_messagesKey));
    _decodeTokens(prefs.getString(_tokensKey));
    _decodeRememberedUsers(prefs.getString(_rememberedUsersKey));
    _decodeVoiceMemberVolumes(prefs.getString(_voiceMemberVolumesKey));

    _activeServerId = prefs.getString(_activeServerIdKey);
    _currentUsername = prefs.getString(_currentUsernameKey);
    _selectedServerId = prefs.getString(_selectedServerIdKey);
    _selectedChannelId = prefs.getString(_selectedChannelIdKey);
    _globalYuid = prefs.getString(_globalYuidKey);

    _localDisplayNamesByAccount.clear();
    _localAvatarSourcesByAccount.clear();

    for (final entry in _membersByServer.entries.toList()) {
      _membersByServer[entry.key] = _applyLocalProfilesToMembers(entry.key, entry.value);
    }

    if (_activeServerId != null && _serverById(_activeServerId) == null) {
      _activeServerId = null;
      _currentUsername = null;
    }

    if (_selectedServerId != null && _serverById(_selectedServerId) == null) {
      _selectedServerId = null;
      _selectedChannelId = null;
    }

    if (_selectedChannelId != null && _channelById(_selectedChannelId) == null) {
      _selectedChannelId = null;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      _serversKey,
      jsonEncode(_servers.map((server) => server.toJson()).toList()),
    );

    await prefs.setString(
      _channelsKey,
      jsonEncode(_channels.map((channel) => channel.toJson()).toList()),
    );

    await prefs.setString(
      _membersKey,
      jsonEncode({
        for (final entry in _membersByServer.entries)
          entry.key: entry.value.map((member) => member.toJson()).toList(),
      }),
    );

    await prefs.setString(
      _messagesKey,
      jsonEncode({
        for (final entry in _messagesByChannel.entries)
          entry.key: entry.value.map((message) => message.toJson()).toList(),
      }),
    );

    await prefs.setString(_tokensKey, jsonEncode(_tokensByServerId));
    await prefs.setString(
      _rememberedUsersKey,
      jsonEncode(_rememberedUsersByServer),
    );

    await prefs.setString(
      _voiceMemberVolumesKey,
      jsonEncode({
        for (final entry in _voiceMemberVolumesByServerId.entries)
          entry.key: entry.value,
      }),
    );

    if (_activeServerId != null) {
      await prefs.setString(_activeServerIdKey, _activeServerId!);
    } else {
      await prefs.remove(_activeServerIdKey);
    }

    if (_currentUsername != null) {
      await prefs.setString(_currentUsernameKey, _currentUsername!);
    } else {
      await prefs.remove(_currentUsernameKey);
    }

    if (_selectedServerId != null && _selectedServerId!.isNotEmpty) {
      await prefs.setString(_selectedServerIdKey, _selectedServerId!);
    } else {
      await prefs.remove(_selectedServerIdKey);
    }

    if (_selectedChannelId != null && _selectedChannelId!.isNotEmpty) {
      await prefs.setString(_selectedChannelIdKey, _selectedChannelId!);
    } else {
      await prefs.remove(_selectedChannelIdKey);
    }

    if (_globalYuid != null && _globalYuid!.isNotEmpty) {
      await prefs.setString(_globalYuidKey, _globalYuid!);
    } else {
      await prefs.remove(_globalYuidKey);
    }
    await prefs.remove(_localProfilesKey);
  }

  void _decodeVoiceMemberVolumes(String? raw) {
    _voiceMemberVolumesByServerId.clear();

    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    for (final entry in decoded.entries) {
      final serverId = entry.key.toString();
      final value = entry.value;
      if (value is! Map) continue;

      final volumes = <String, double>{};
      for (final subEntry in value.entries) {
        final parsed = switch (subEntry.value) {
          num value => value.toDouble(),
          String value => double.tryParse(value),
          _ => null,
        };
        if (parsed == null) continue;
        final safe = parsed.clamp(0.0, 1.5).toDouble();
        if ((safe - 1.0).abs() < 0.001) continue;
        volumes[subEntry.key.toString()] = safe;
      }

      if (volumes.isNotEmpty) {
        _voiceMemberVolumesByServerId[serverId] = volumes;
      }
    }
  }

  void _decodeServers(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! List) return;

    _servers
      ..clear()
      ..addAll(
        decoded
            .whereType<Map>()
            .map((item) => ChatServer.fromJson(Map<String, dynamic>.from(item))),
      );
  }

  void _decodeChannels(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! List) return;

    _channels
      ..clear()
      ..addAll(
        decoded
            .whereType<Map>()
            .map(
              (item) => ChatChannel.fromJson(Map<String, dynamic>.from(item)),
            ),
      );
  }

  void _decodeMembers(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    _membersByServer
      ..clear()
      ..addAll(
        decoded.map(
          (key, value) => MapEntry(
            key.toString(),
            (value as List)
                .whereType<Map>()
                .map((item) => Member.fromJson(Map<String, dynamic>.from(item)))
                .toList(),
          ),
        ),
      );
  }

  void _decodeMessages(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    _messagesByChannel
      ..clear()
      ..addAll(
        decoded.map(
          (key, value) => MapEntry(
            key.toString(),
            (value as List)
                .whereType<Map>()
                .map(
                  (item) => ChatMessage.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(),
          ),
        ),
      );
  }

  void _decodeTokens(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    _tokensByServerId
      ..clear()
      ..addAll(
        decoded.map((key, value) => MapEntry(key.toString(), value.toString())),
      );
  }

  void _decodeRememberedUsers(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    _rememberedUsersByServer
      ..clear()
      ..addAll(
        decoded.map((key, value) => MapEntry(key.toString(), value.toString())),
      );
  }
}