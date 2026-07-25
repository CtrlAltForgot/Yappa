import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'media_device_identity_service.dart';
import 'media_key_envelope.dart';
import 'media_room_state.dart';
import 'yuid_identity_service.dart';

enum MediaE2eeStatus { idle, establishing, encrypted, failed }

class MediaE2eeSessionKey {
  final String serverId;
  final String channelId;
  final int epoch;
  final int keyIndex;
  final Uint8List bytes;

  const MediaE2eeSessionKey({
    required this.serverId,
    required this.channelId,
    required this.epoch,
    required this.keyIndex,
    required this.bytes,
  });
}

class MediaE2eeCoordinator {
  final MediaDeviceIdentityService _deviceIdentity;
  final YuidIdentityService _yuidIdentity;
  final Future<void> Function(MediaKeyEnvelope envelope) _sendEnvelope;
  final Future<void> Function(
    MediaE2eeSessionKey key,
    List<String> participantDeviceIds,
  )
  _onKeyChanged;
  final Future<void> Function(int keyIndex, List<String> participantDeviceIds)
  _onKeyUnavailable;
  final void Function(Object error) _onError;
  final void Function(MediaE2eeStatus status) _onStatusChanged;
  final MediaKeyEnvelopeCryptor _envelopes = MediaKeyEnvelopeCryptor();
  final MediaRoomStateVerifier _roomVerifier = MediaRoomStateVerifier();

  String? _serverId;
  String? _channelId;
  String? _deviceId;
  MediaRoomState? _roomState;
  MediaE2eeSessionKey? _sessionKey;
  Completer<MediaE2eeSessionKey>? _keyCompleter;
  Future<void> _eventQueue = Future<void>.value();
  int _outgoingSequence = 0;
  int _lastIncomingSequence = 0;
  int _generation = 0;
  MediaE2eeStatus _status = MediaE2eeStatus.idle;

  MediaE2eeCoordinator({
    required MediaDeviceIdentityService deviceIdentity,
    required YuidIdentityService yuidIdentity,
    required Future<void> Function(MediaKeyEnvelope envelope) sendEnvelope,
    required Future<void> Function(
      MediaE2eeSessionKey key,
      List<String> participantDeviceIds,
    )
    onKeyChanged,
    required Future<void> Function(
      int keyIndex,
      List<String> participantDeviceIds,
    )
    onKeyUnavailable,
    required void Function(Object error) onError,
    required void Function(MediaE2eeStatus status) onStatusChanged,
  }) : _deviceIdentity = deviceIdentity,
       _yuidIdentity = yuidIdentity,
       _sendEnvelope = sendEnvelope,
       _onKeyChanged = onKeyChanged,
       _onKeyUnavailable = onKeyUnavailable,
       _onError = onError,
       _onStatusChanged = onStatusChanged;

  MediaE2eeSessionKey? get sessionKey => _sessionKey;
  MediaRoomState? get roomState => _roomState;
  MediaE2eeStatus get status => _status;

  Future<void> begin({
    required String serverId,
    required String channelId,
  }) async {
    end();
    final generation = _generation;
    final identity = await _deviceIdentity.getOrCreateIdentity();
    _ensureCurrentGeneration(generation);
    _serverId = serverId;
    _channelId = channelId;
    _deviceId = identity.deviceId;
    _keyCompleter = _newKeyCompleter();
    _setStatus(MediaE2eeStatus.establishing);
  }

  Future<MediaE2eeSessionKey> waitForKey({
    Duration timeout = const Duration(seconds: 12),
  }) {
    final existing = _sessionKey;
    if (existing != null) return Future.value(existing);
    final completer = _keyCompleter;
    if (completer == null) {
      return Future.error(
        StateError('Encrypted media coordination has not started.'),
      );
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Timed out establishing end-to-end media encryption.',
      ),
    );
  }

  void handleRoomState(MediaRoomState state) {
    _queueEvent((generation) => _applyRoomState(state, generation));
  }

  void handleEnvelope(MediaKeyEnvelope envelope) {
    _queueEvent((generation) => _openEnvelope(envelope, generation));
  }

  void _queueEvent(Future<void> Function(int generation) action) {
    final generation = _generation;
    _eventQueue = _eventQueue
        .then((_) {
          _ensureCurrentGeneration(generation);
          return action(generation);
        })
        .catchError((error) async {
          if (generation != _generation) return;
          _clearSessionKey();
          var completer = _keyCompleter;
          if (completer == null || completer.isCompleted) {
            completer = _newKeyCompleter();
            _keyCompleter = completer;
          }
          completer.completeError(error);
          _setStatus(MediaE2eeStatus.failed);
          _onError(error);
          final state = _roomState;
          if (state != null) {
            try {
              await _onKeyUnavailable(
                state.epoch % 256,
                state.devices
                    .map((device) => device.id)
                    .toList(growable: false),
              );
            } catch (quarantineError) {
              if (generation == _generation) {
                _onError(quarantineError);
              }
            }
          }
        });
  }

  Future<void> _applyRoomState(MediaRoomState state, int generation) async {
    final serverId = _serverId;
    final channelId = _channelId;
    final deviceId = _deviceId;
    if (serverId == null || channelId == null || deviceId == null) return;
    final previous = _roomState;
    await _roomVerifier.verify(
      state,
      expectedServerId: serverId,
      expectedChannelId: channelId,
      minimumEpoch: previous?.epoch,
      minimumMembershipSequence: previous?.membershipSequence,
    );
    _ensureCurrentGeneration(generation);
    if (!state.devices.any((device) => device.id == deviceId)) {
      throw const FormatException(
        'This device is absent from encrypted room membership.',
      );
    }

    final epochChanged = previous == null || state.epoch != previous.epoch;
    if (epochChanged) {
      _clearSessionKey();
      _outgoingSequence = 0;
      _lastIncomingSequence = 0;
      _keyCompleter = _newKeyCompleter();
    }
    _roomState = state;
    if (epochChanged) {
      _setStatus(MediaE2eeStatus.establishing);
      await _onKeyUnavailable(
        state.epoch % 256,
        state.devices.map((device) => device.id).toList(growable: false),
      );
      _ensureCurrentGeneration(generation);
    }

    if (state.leaderDeviceId != deviceId) {
      final sessionKey = _sessionKey;
      if (sessionKey != null) {
        await _onKeyChanged(
          sessionKey,
          state.devices.map((device) => device.id).toList(growable: false),
        );
        _ensureCurrentGeneration(generation);
      }
      return;
    }
    if (_sessionKey == null) {
      final randomKey = await SecretKeyData.random(length: 32).extractBytes();
      _ensureCurrentGeneration(generation);
      await _setSessionKey(
        MediaE2eeSessionKey(
          serverId: serverId,
          channelId: channelId,
          epoch: state.epoch,
          keyIndex: state.epoch % 256,
          bytes: Uint8List.fromList(randomKey),
        ),
        generation,
      );
    }
    await _sendCurrentKeyToMembers(state, generation);
  }

  Future<void> _sendCurrentKeyToMembers(
    MediaRoomState state,
    int generation,
  ) async {
    final sessionKey = _sessionKey;
    final deviceId = _deviceId;
    if (sessionKey == null || deviceId == null) return;
    final senderKeyPair = await _yuidIdentity.keyPair();
    _ensureCurrentGeneration(generation);
    for (final recipient in state.devices) {
      if (recipient.id == deviceId) continue;
      _outgoingSequence += 1;
      final envelope = await _envelopes.seal(
        context: MediaRoomContext(
          serverId: state.serverId,
          channelId: state.channelId,
          epoch: state.epoch,
          senderDeviceId: deviceId,
          recipientDeviceId: recipient.id,
        ),
        messageSequence: _outgoingSequence,
        roomKey: sessionKey.bytes,
        keyIndex: sessionKey.keyIndex,
        createdAt: DateTime.now().toUtc(),
        recipientMediaPublicKey: SimplePublicKey(
          _decodeBase64Url(recipient.publicKey),
          type: KeyPairType.x25519,
        ),
        senderYuidKeyPair: senderKeyPair,
      );
      _ensureCurrentGeneration(generation);
      await _sendEnvelope(envelope);
      _ensureCurrentGeneration(generation);
    }
  }

  Future<void> _openEnvelope(MediaKeyEnvelope envelope, int generation) async {
    final state = _roomState;
    final deviceId = _deviceId;
    if (state == null || deviceId == null) return;
    if (envelope.messageSequence <= _lastIncomingSequence ||
        envelope.recipientDeviceId != deviceId ||
        envelope.epoch != state.epoch) {
      throw const FormatException('Stale or misdirected media key envelope.');
    }
    MediaDevicePublicIdentity? sender;
    for (final candidate in state.devices) {
      if (candidate.id == envelope.senderDeviceId) {
        sender = candidate;
        break;
      }
    }
    if (sender == null || sender.id != state.leaderDeviceId) {
      throw const FormatException(
        'Media key envelope did not come from the elected leader.',
      );
    }
    final opened = await _envelopes.open(
      envelope: envelope,
      expectedContext: MediaRoomContext(
        serverId: state.serverId,
        channelId: state.channelId,
        epoch: state.epoch,
        senderDeviceId: sender.id,
        recipientDeviceId: deviceId,
      ),
      recipientMediaKeyPair: await _deviceIdentity.keyPair(),
      authorizedSenderYuidPublicKey: SimplePublicKey(
        _decodeBase64Url(sender.yuidPublicKey),
        type: KeyPairType.ed25519,
      ),
    );
    _ensureCurrentGeneration(generation);
    final now = DateTime.now().toUtc();
    if (opened.keyIndex != state.epoch % 256 ||
        opened.createdAt.isAfter(now.add(const Duration(minutes: 2))) ||
        opened.createdAt.isBefore(now.subtract(const Duration(minutes: 10)))) {
      throw const FormatException('Invalid encrypted media room key payload.');
    }
    _lastIncomingSequence = envelope.messageSequence;
    await _setSessionKey(
      MediaE2eeSessionKey(
        serverId: state.serverId,
        channelId: state.channelId,
        epoch: state.epoch,
        keyIndex: opened.keyIndex,
        bytes: Uint8List.fromList(opened.roomKey),
      ),
      generation,
    );
  }

  Future<void> _setSessionKey(MediaE2eeSessionKey key, int generation) async {
    _ensureCurrentGeneration(generation);
    _clearSessionKey();
    _sessionKey = key;
    final state = _roomState;
    if (state != null) {
      await _onKeyChanged(
        key,
        state.devices.map((device) => device.id).toList(growable: false),
      );
      _ensureCurrentGeneration(generation);
    }
    final completer = _keyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(key);
    }
    _setStatus(MediaE2eeStatus.encrypted);
  }

  void _clearSessionKey() {
    _sessionKey?.bytes.fillRange(0, _sessionKey!.bytes.length, 0);
    _sessionKey = null;
  }

  void end() {
    _generation += 1;
    _clearSessionKey();
    final completer = _keyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        StateError('Encrypted media coordination ended.'),
      );
    }
    _serverId = null;
    _channelId = null;
    _deviceId = null;
    _roomState = null;
    _keyCompleter = null;
    _outgoingSequence = 0;
    _lastIncomingSequence = 0;
    _eventQueue = Future<void>.value();
    _setStatus(MediaE2eeStatus.idle);
  }

  void _ensureCurrentGeneration(int generation) {
    if (generation != _generation) {
      throw StateError('Encrypted media coordination was superseded.');
    }
  }

  Completer<MediaE2eeSessionKey> _newKeyCompleter() {
    final completer = Completer<MediaE2eeSessionKey>();
    // A room may end before a caller starts waiting. Observe the internal
    // future so completing it with an error can never become an unhandled
    // asynchronous exception; waitForKey still receives the same error.
    unawaited(completer.future.then<void>((_) {}, onError: (_) {}));
    return completer;
  }

  void _setStatus(MediaE2eeStatus status) {
    if (_status == status) return;
    _status = status;
    _onStatusChanged(status);
  }

  Uint8List _decodeBase64Url(String value) {
    final padding = (4 - value.length % 4) % 4;
    return Uint8List.fromList(
      base64Url.decode(value.padRight(value.length + padding, '=')),
    );
  }
}
