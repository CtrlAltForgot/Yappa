import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/channel_model.dart';
import '../models/member_model.dart';
import '../models/message_model.dart';
import '../models/server_model.dart';
import '../models/voice_models.dart';

typedef RealtimeHelloCallback = void Function(
  ChatServer server,
  List<ChatChannel> channels,
  List<Member> members,
  List<VoiceDeckState> voice,
  VoicePresenceState meVoiceState,
);

typedef RealtimePresenceCallback = void Function(
  List<Member> members,
  List<VoiceDeckState> voice,
);

typedef RealtimeMessageCallback = void Function(ChatMessage message);
typedef RealtimeMessageDeletedCallback = void Function(
  String channelId,
  String messageId,
);

typedef RealtimeServerUpdatedCallback = void Function(
  ChatServer server,
  List<ChatChannel> channels,
  List<VoiceDeckState> voice,
);

typedef RealtimeErrorCallback = void Function(String message);

typedef RealtimeVoiceOfferCallback = void Function(
  String fromUserId,
  String channelId,
  Map<String, dynamic> description,
);

typedef RealtimeVoiceAnswerCallback = void Function(
  String fromUserId,
  String channelId,
  Map<String, dynamic> description,
);

typedef RealtimeVoiceIceCandidateCallback = void Function(
  String fromUserId,
  String channelId,
  Map<String, dynamic> candidate,
);

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

  final RealtimeVoiceOfferCallback? onVoiceOffer;
  final RealtimeVoiceAnswerCallback? onVoiceAnswer;
  final RealtimeVoiceIceCandidateCallback? onVoiceIceCandidate;

  io.Socket? _socket;
  Timer? _presencePingTimer;

  RealtimeClient({
    required this.onHello,
    required this.onPresenceUpdate,
    required this.onMessage,
    required this.onMessageUpdated,
    required this.onMessageDeleted,
    required this.onServerUpdated,
    required this.onError,
    this.onVoiceOffer,
    this.onVoiceAnswer,
    this.onVoiceIceCandidate,
  });

  bool get isConnected => _socket?.connected == true;

  ChatMessage _resolveRealtimeMessage(ChatMessage message, ChatServer server) {
    final normalizedBase = server.address.replaceFirst(RegExp(r'/*$'), '');
    return message.resolvedAgainst(normalizedBase);
  }

  void connect({
    required ChatServer server,
    required String token,
  }) {
    dispose();

    final uri = _socketBaseUrl(server.address);

    final socket = io.io(
      uri,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setAuth({'token': token})
          .enableForceNew()
          .enableReconnection()
          .setReconnectionAttempts(999999)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    socket.onConnect((_) {
      _startPresencePing();
    });

    socket.onDisconnect((_) {
      _stopPresencePing();
    });

    socket.onConnectError((error) {
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
          ChatServer.fromJson({
            ...serverJson,
            'address': server.address,
          }),
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
          ChatServer.fromJson({
            ...serverJson,
            'address': server.address,
          }),
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

    _socket = socket;
    socket.connect();
  }

  Future<VoiceJoinResult> joinVoiceDeck(String channelId) async {
    final response = await _emitWithAck(
      'voice:join',
      {'channelId': channelId},
    );

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
      throw Exception(_extractAckError(response, 'Could not leave voice deck.'));
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
    final response = await _emitWithAck(
      'voice:signal:offer',
      {
        'toUserId': toUserId,
        'channelId': channelId,
        'sdp': sdp,
        'type': type,
      },
    );

    if (response['ok'] != true) {
      throw Exception(_extractAckError(response, 'Could not send voice offer.'));
    }
  }

  Future<void> sendVoiceAnswer({
    required String toUserId,
    required String channelId,
    required String sdp,
    required String type,
  }) async {
    final response = await _emitWithAck(
      'voice:signal:answer',
      {
        'toUserId': toUserId,
        'channelId': channelId,
        'sdp': sdp,
        'type': type,
      },
    );

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
    final response = await _emitWithAck(
      'voice:signal:ice-candidate',
      {
        'toUserId': toUserId,
        'channelId': channelId,
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      },
    );

    if (response['ok'] != true) {
      throw Exception(
        _extractAckError(response, 'Could not send ICE candidate.'),
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

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, val) => MapEntry(key.toString(), val),
      );
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
    _stopPresencePing();
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
  }
}