import 'dart:async';
import 'dart:io';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/channel_model.dart';
import '../models/member_model.dart';
import '../models/message_model.dart';
import '../models/server_model.dart';
import '../models/voice_models.dart';
import 'media_key_envelope.dart';
import 'media_room_state.dart';
import 'mls_delivery_models.dart';

typedef RealtimeHelloCallback =
    void Function(
      ChatServer server,
      List<ChatChannel> channels,
      List<Member> members,
      List<VoiceDeckState> voice,
      VoicePresenceState meVoiceState,
    );

typedef RealtimePresenceCallback =
    void Function(List<Member> members, List<VoiceDeckState> voice);

typedef RealtimeMessageCallback = void Function(ChatMessage message);
typedef RealtimeMessageDeletedCallback =
    void Function(String channelId, String messageId);

typedef RealtimeServerUpdatedCallback =
    void Function(
      ChatServer server,
      List<ChatChannel> channels,
      List<VoiceDeckState> voice,
    );

typedef RealtimeErrorCallback = void Function(String message);
typedef RealtimeLifecycleCallback = void Function();

typedef RealtimeVoiceOfferCallback =
    void Function(
      String fromUserId,
      String channelId,
      Map<String, dynamic> description,
    );

typedef RealtimeVoiceAnswerCallback =
    void Function(
      String fromUserId,
      String channelId,
      Map<String, dynamic> description,
    );

typedef RealtimeVoiceIceCandidateCallback =
    void Function(
      String fromUserId,
      String channelId,
      Map<String, dynamic> candidate,
    );
typedef RealtimeMediaRoomStateCallback = void Function(MediaRoomState state);
typedef RealtimeMediaEnvelopeCallback =
    void Function(MediaKeyEnvelope envelope);
typedef RealtimeMlsDeliveryCallback = void Function(MlsDeliveryMessage message);
typedef RealtimeHistoryRecoveryReadyCallback =
    void Function(String channelId, String transferId);

class VoiceJoinResult {
  final String channelId;
  final String channelName;
  final DateTime? joinedAt;

  const VoiceJoinResult({
    required this.channelId,
    required this.channelName,
    required this.joinedAt,
  });
}

class RealtimeClient {
  final RealtimeHelloCallback onHello;
  final RealtimePresenceCallback onPresenceUpdate;
  final RealtimeMessageCallback onMessage;
  final RealtimeMessageCallback onMessageUpdated;
  final RealtimeMessageDeletedCallback onMessageDeleted;
  final RealtimeServerUpdatedCallback onServerUpdated;
  final RealtimeErrorCallback onError;
  final RealtimeLifecycleCallback? onConnected;
  final RealtimeLifecycleCallback? onUnavailable;

  final RealtimeVoiceOfferCallback? onVoiceOffer;
  final RealtimeVoiceAnswerCallback? onVoiceAnswer;
  final RealtimeVoiceIceCandidateCallback? onVoiceIceCandidate;
  final RealtimeMediaRoomStateCallback? onMediaRoomState;
  final RealtimeMediaEnvelopeCallback? onMediaEnvelope;
  final RealtimeMlsDeliveryCallback? onMlsDelivery;
  final RealtimeHistoryRecoveryReadyCallback? onHistoryRecoveryReady;

  io.Socket? _socket;
  Timer? _presencePingTimer;
  bool _disposed = false;
  bool _reportedUnavailable = false;

  RealtimeClient({
    required this.onHello,
    required this.onPresenceUpdate,
    required this.onMessage,
    required this.onMessageUpdated,
    required this.onMessageDeleted,
    required this.onServerUpdated,
    required this.onError,
    this.onConnected,
    this.onUnavailable,
    this.onVoiceOffer,
    this.onVoiceAnswer,
    this.onVoiceIceCandidate,
    this.onMediaRoomState,
    this.onMediaEnvelope,
    this.onMlsDelivery,
    this.onHistoryRecoveryReady,
  });

  bool get isConnected => _socket?.connected == true;

  ChatMessage _resolveRealtimeMessage(ChatMessage message, ChatServer server) {
    final normalizedBase = server.address.replaceFirst(RegExp(r'/*$'), '');
    return message.resolvedAgainst(normalizedBase);
  }

  void connect({
    required ChatServer server,
    required String token,
    bool useLanRoute = false,
  }) {
    dispose();
    _disposed = false;
    _reportedUnavailable = false;

    final uri = _socketBaseUrl(server.address);
    final options = io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .setAuth({'token': token})
        .enableForceNew()
        .enableReconnection()
        .setReconnectionAttempts(999999)
        .setReconnectionDelay(1000)
        .setReconnectionDelayMax(5000);
    if (useLanRoute &&
        server.lanAddress.trim().isNotEmpty &&
        server.lanTlsPort != null &&
        Uri.parse(uri).scheme == 'https') {
      options.setHttpClientAdapter(
        _SecureLanWebSocketAdapter(
          publicOrigin: Uri.parse(uri).origin,
          lanHost: server.lanAddress,
          lanPort: server.lanTlsPort!,
        ),
      );
    }

    final socket = io.io(uri, options.build());

    socket.onConnect((_) {
      _reportedUnavailable = false;
      _startPresencePing();
      onConnected?.call();
    });

    socket.onDisconnect((_) {
      _stopPresencePing();
      _reportUnavailable();
    });

    socket.onConnectError((error) {
      _reportUnavailable();
      onError('Realtime connect error: $error');
    });

    socket.onError((error) {
      onError('Realtime socket error: $error');
    });

    socket.on('server:hello', (payload) {
      try {
        final map = _asMap(payload);
        final serverJson = _asMap(map['server']);
        final channelsJson = _asListOfMap(map['channels']);
        final membersJson = _asListOfMap(map['members']);
        final voiceJson = _asListOfMap(map['voice']);
        final meJson = _asMap(map['me']);
        final meVoiceStateJson = _asMap(meJson['voiceState']);

        onHello(
          ChatServer.fromJson({...serverJson, 'address': server.address}),
          channelsJson.map(ChatChannel.fromJson).toList(growable: false),
          membersJson.map(Member.fromJson).toList(growable: false),
          voiceJson.map(VoiceDeckState.fromJson).toList(growable: false),
          VoicePresenceState.fromJson(meVoiceStateJson),
        );
      } catch (error) {
        onError('Failed to parse realtime hello: $error');
      }
    });

    socket.on('presence:update', (payload) {
      try {
        final map = _asMap(payload);
        final membersJson = _asListOfMap(map['members']);
        final voiceJson = _asListOfMap(map['voice']);

        onPresenceUpdate(
          membersJson.map(Member.fromJson).toList(growable: false),
          voiceJson.map(VoiceDeckState.fromJson).toList(growable: false),
        );
      } catch (error) {
        onError('Failed to parse presence update: $error');
      }
    });

    socket.on('message:new', (payload) {
      try {
        final map = _asMap(payload);
        final messageJson = _asMap(map['message']);
        onMessage(
          _resolveRealtimeMessage(ChatMessage.fromJson(messageJson), server),
        );
      } catch (error) {
        onError('Failed to parse realtime message: $error');
      }
    });

    socket.on('message:update', (payload) {
      try {
        final map = _asMap(payload);
        final messageJson = _asMap(map['message']);
        onMessageUpdated(
          _resolveRealtimeMessage(ChatMessage.fromJson(messageJson), server),
        );
      } catch (error) {
        onError('Failed to parse realtime message update: $error');
      }
    });

    socket.on('message:delete', (payload) {
      try {
        final map = _asMap(payload);
        onMessageDeleted(
          _readString(map['channelId']),
          _readString(map['messageId']),
        );
      } catch (error) {
        onError('Failed to parse realtime message delete: $error');
      }
    });

    socket.on('server:update', (payload) {
      try {
        final map = _asMap(payload);
        final serverJson = _asMap(map['server']);
        final channelsJson = _asListOfMap(map['channels']);
        final voiceJson = _asListOfMap(map['voice']);

        onServerUpdated(
          ChatServer.fromJson({...serverJson, 'address': server.address}),
          channelsJson.map(ChatChannel.fromJson).toList(growable: false),
          voiceJson.map(VoiceDeckState.fromJson).toList(growable: false),
        );
      } catch (error) {
        onError('Failed to parse server update: $error');
      }
    });

    socket.on('voice:signal:offer', (payload) {
      try {
        if (onVoiceOffer == null) return;
        final map = _asMap(payload);
        onVoiceOffer!(
          _readString(map['fromUserId']),
          _readString(map['channelId']),
          _asMap(map['description']),
        );
      } catch (error) {
        onError('Failed to parse voice offer: $error');
      }
    });

    socket.on('voice:signal:answer', (payload) {
      try {
        if (onVoiceAnswer == null) return;
        final map = _asMap(payload);
        onVoiceAnswer!(
          _readString(map['fromUserId']),
          _readString(map['channelId']),
          _asMap(map['description']),
        );
      } catch (error) {
        onError('Failed to parse voice answer: $error');
      }
    });

    socket.on('voice:signal:ice-candidate', (payload) {
      try {
        if (onVoiceIceCandidate == null) return;
        final map = _asMap(payload);
        onVoiceIceCandidate!(
          _readString(map['fromUserId']),
          _readString(map['channelId']),
          _asMap(map['candidate']),
        );
      } catch (error) {
        onError('Failed to parse voice ICE candidate: $error');
      }
    });

    socket.on('media:e2ee:state', (payload) {
      try {
        if (onMediaRoomState == null) return;
        onMediaRoomState!(MediaRoomState.fromJson(_asMap(payload)));
      } catch (error) {
        onError('Failed to parse encrypted room state: $error');
      }
    });

    socket.on('media:e2ee:envelope', (payload) {
      try {
        if (onMediaEnvelope == null) return;
        final map = _asMap(payload);
        onMediaEnvelope!(MediaKeyEnvelope.fromJson(_asMap(map['envelope'])));
      } catch (error) {
        onError('Failed to parse encrypted media key envelope: $error');
      }
    });

    socket.on('mls:message', (payload) {
      try {
        if (onMlsDelivery == null) return;
        final map = _asMap(payload);
        onMlsDelivery!(MlsDeliveryMessage.fromJson(_asMap(map['message'])));
      } catch (error) {
        onError('Failed to parse encrypted message delivery: $error');
      }
    });

    socket.on('history-recovery:ready', (payload) {
      try {
        if (onHistoryRecoveryReady == null) return;
        final map = _asMap(payload);
        onHistoryRecoveryReady!(
          _readString(map['channelId']),
          _readString(map['transferId']),
        );
      } catch (error) {
        onError('Failed to parse encrypted-history recovery update: $error');
      }
    });

    _socket = socket;
    socket.connect();
  }

  Future<VoiceJoinResult> joinVoiceDeck(String channelId) async {
    final response = await _emitWithAck('voice:join', {'channelId': channelId});

    if (response['ok'] != true) {
      throw Exception(_extractAckError(response, 'Could not join voice deck.'));
    }

    return VoiceJoinResult(
      channelId: _readString(response['channelId']),
      channelName: _readString(response['channelName']),
      joinedAt: _parseDateTimeOrNull(response['joinedAt']),
    );
  }

  Future<void> leaveVoiceDeck() async {
    final response = await _emitWithAck('voice:leave', {});

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not leave voice deck.'),
      );
    }
  }

  Future<VoicePresenceState> updateVoiceState({
    bool? micMuted,
    bool? audioMuted,
    bool? cameraEnabled,
    bool? screenShareEnabled,
    bool? speaking,
  }) async {
    final payload = <String, dynamic>{};
    if (micMuted != null) payload['micMuted'] = micMuted;
    if (audioMuted != null) payload['audioMuted'] = audioMuted;
    if (cameraEnabled != null) payload['cameraEnabled'] = cameraEnabled;
    if (screenShareEnabled != null) {
      payload['screenShareEnabled'] = screenShareEnabled;
    }
    if (speaking != null) payload['speaking'] = speaking;

    final response = await _emitWithAck('voice:state', payload);

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not update voice state.'),
      );
    }

    return VoicePresenceState.fromJson(_asMap(response['voiceState']));
  }

  Future<VoicePresenceState> setSpeaking(bool speaking) async {
    final state = await updateVoiceState(speaking: speaking);
    return state.copyWith(speaking: speaking);
  }

  Future<void> sendVoiceOffer({
    required String toUserId,
    required String channelId,
    required String sdp,
    required String type,
  }) async {
    final response = await _emitWithAck('voice:signal:offer', {
      'toUserId': toUserId,
      'channelId': channelId,
      'sdp': sdp,
      'type': type,
    });

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not send voice offer.'),
      );
    }
  }

  Future<void> sendVoiceAnswer({
    required String toUserId,
    required String channelId,
    required String sdp,
    required String type,
  }) async {
    final response = await _emitWithAck('voice:signal:answer', {
      'toUserId': toUserId,
      'channelId': channelId,
      'sdp': sdp,
      'type': type,
    });

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not send voice answer.'),
      );
    }
  }

  Future<void> sendVoiceIceCandidate({
    required String toUserId,
    required String channelId,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    final response = await _emitWithAck('voice:signal:ice-candidate', {
      'toUserId': toUserId,
      'channelId': channelId,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not send ICE candidate.'),
      );
    }
  }

  Future<void> sendMediaKeyEnvelope(MediaKeyEnvelope envelope) async {
    final response = await _emitWithAck('media:e2ee:envelope', {
      'envelope': envelope.toJson(),
    });
    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(
          response,
          'Could not deliver encrypted media room key.',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> _emitWithAck(
    String event,
    Map<String, dynamic> payload,
  ) async {
    final socket = _socket;
    if (socket == null || socket.disconnected) {
      throw Exception('Realtime connection is not active.');
    }

    final completer = Completer<Map<String, dynamic>>();

    socket.emitWithAck(
      event,
      payload,
      ack: (data) {
        try {
          completer.complete(_asMap(data));
        } catch (error) {
          completer.completeError(
            Exception('Invalid ack payload for $event: $error'),
          );
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw Exception('Timed out waiting for $event response.');
      },
    );
  }

  String _socketBaseUrl(String address) {
    final raw = address.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    return 'http://$raw';
  }

  void _startPresencePing() {
    _stopPresencePing();
    _presencePingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        _socket?.emit('presence:ping');
      } catch (_) {}
    });
  }

  void _stopPresencePing() {
    _presencePingTimer?.cancel();
    _presencePingTimer = null;
  }

  void _reportUnavailable() {
    if (_disposed || _reportedUnavailable) return;
    _reportedUnavailable = true;
    onUnavailable?.call();
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    throw Exception('Expected map but got ${value.runtimeType}');
  }

  List<Map<String, dynamic>> _asListOfMap(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value.map(_asMap).toList(growable: false);
  }

  String _readString(dynamic value) {
    if (value == null) return '';
    return value.toString();
  }

  DateTime? _parseDateTimeOrNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  String _extractAckError(Map<String, dynamic> response, String fallback) {
    final error = response['error'];
    if (error is String && error.trim().isNotEmpty) {
      return error.trim();
    }
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
    return fallback;
  }

  void dispose() {
    _disposed = true;
    _stopPresencePing();
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
  }
}

class _SecureLanWebSocketAdapter implements io.HttpClientAdapter {
  final Uri publicUri;
  final String lanHost;
  final int lanPort;

  _SecureLanWebSocketAdapter({
    required String publicOrigin,
    required this.lanHost,
    required this.lanPort,
  }) : publicUri = Uri.parse(publicOrigin);

  @override
  Future<dynamic> connect(String uri, {Map<String, dynamic>? headers}) {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 6);
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      if (proxyHost != null ||
          proxyPort != null ||
          requestUri.scheme != 'https' ||
          requestUri.host.toLowerCase() != publicUri.host.toLowerCase() ||
          !isExpectedSecureLanWebSocketPort(requestUri.port, publicUri)) {
        throw const SocketException('Invalid secure LAN socket route.');
      }
      final rawTask = await Socket.startConnect(lanHost, lanPort);
      final secureSocket = rawTask.socket.then(
        (socket) => SecureSocket.secure(socket, host: requestUri.host),
      );
      return ConnectionTask.fromSocket(secureSocket, rawTask.cancel);
    };
    return WebSocket.connect(uri, headers: headers, customClient: client);
  }
}

bool isExpectedSecureLanWebSocketPort(int requestPort, Uri publicUri) {
  final publicPort = publicUri.hasPort ? publicUri.port : 443;
  // Dart's WebSocket implementation currently converts a wss URI without an
  // explicit port into an internal HTTPS request whose reported port is zero.
  return requestPort == 0 || requestPort == publicPort;
}
