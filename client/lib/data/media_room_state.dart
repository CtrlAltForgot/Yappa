import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'ed25519_verifier.dart';

class MediaDevicePublicIdentity {
  final String id;
  final String userId;
  final String publicKey;
  final String yuidAuthorizationSignature;
  final String authorizationNonce;
  final String authorizedUsername;
  final String username;
  final String yuid;
  final String yuidPublicKey;

  const MediaDevicePublicIdentity({
    required this.id,
    required this.userId,
    required this.publicKey,
    required this.yuidAuthorizationSignature,
    required this.authorizationNonce,
    required this.authorizedUsername,
    required this.username,
    required this.yuid,
    required this.yuidPublicKey,
  });

  factory MediaDevicePublicIdentity.fromJson(Map<String, dynamic> json) {
    return MediaDevicePublicIdentity(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      publicKey: json['publicKey']?.toString() ?? '',
      yuidAuthorizationSignature:
          json['yuidAuthorizationSignature']?.toString() ?? '',
      authorizationNonce: json['authorizationNonce']?.toString() ?? '',
      authorizedUsername: json['authorizedUsername']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      yuid: json['yuid']?.toString() ?? '',
      yuidPublicKey: json['yuidPublicKey']?.toString() ?? '',
    );
  }
}

class MediaRoomState {
  final String protocol;
  final String serverId;
  final String channelId;
  final int epoch;
  final int membershipSequence;
  final String leaderDeviceId;
  final List<MediaDevicePublicIdentity> devices;

  const MediaRoomState({
    required this.protocol,
    required this.serverId,
    required this.channelId,
    required this.epoch,
    required this.membershipSequence,
    required this.leaderDeviceId,
    required this.devices,
  });

  factory MediaRoomState.fromJson(Map<String, dynamic> json) {
    final rawDevices = json['devices'];
    return MediaRoomState(
      protocol: json['protocol']?.toString() ?? '',
      serverId: json['serverId']?.toString() ?? '',
      channelId: json['channelId']?.toString() ?? '',
      epoch: (json['epoch'] as num?)?.toInt() ?? 0,
      membershipSequence: (json['membershipSequence'] as num?)?.toInt() ?? 0,
      leaderDeviceId: json['leaderDeviceId']?.toString() ?? '',
      devices: rawDevices is List
          ? rawDevices
                .whereType<Map>()
                .map(
                  (item) => MediaDevicePublicIdentity.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class MediaRoomStateVerifier {
  static const _protocol = 'yappa-media-room-v1';
  final Ed25519Verifier _signatures = Ed25519Verifier();
  final Sha256 _hash = Sha256();

  Future<void> verify(
    MediaRoomState state, {
    required String expectedServerId,
    required String expectedChannelId,
    int? minimumEpoch,
    int? minimumMembershipSequence,
  }) async {
    if (state.protocol != _protocol ||
        state.serverId != expectedServerId ||
        state.channelId != expectedChannelId ||
        state.epoch < 1 ||
        state.membershipSequence < 1 ||
        (minimumEpoch != null && state.epoch < minimumEpoch) ||
        (minimumMembershipSequence != null &&
            state.membershipSequence < minimumMembershipSequence) ||
        state.devices.isEmpty) {
      throw const FormatException('Invalid or stale encrypted room state.');
    }

    final ids = state.devices.map((device) => device.id).toList();
    final sortedIds = [...ids]..sort();
    if (ids.toSet().length != ids.length ||
        !_sameStrings(ids, sortedIds) ||
        state.leaderDeviceId != sortedIds.first) {
      throw const FormatException('Invalid encrypted room membership.');
    }

    for (final device in state.devices) {
      await _verifyDevice(device, expectedServerId);
    }
  }

  Future<void> _verifyDevice(
    MediaDevicePublicIdentity device,
    String serverId,
  ) async {
    if (!RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(device.id) ||
        device.userId.isEmpty ||
        device.username.trim().toLowerCase() != device.authorizedUsername ||
        !RegExp(
          r'^[A-Za-z0-9_-]{22,128}$',
        ).hasMatch(device.authorizationNonce)) {
      throw const FormatException('Invalid media device identity.');
    }
    try {
      final mediaPublicKey = _decodeBase64Url(device.publicKey);
      final yuidPublicKey = _decodeBase64Url(device.yuidPublicKey);
      final authorization = _decodeBase64Url(device.yuidAuthorizationSignature);
      if (mediaPublicKey.length != 32 ||
          yuidPublicKey.length != 32 ||
          authorization.length != 64) {
        throw const FormatException('Invalid media device key material.');
      }
      final digest = await _hash.hash(yuidPublicKey);
      final expectedYuid = _encodeBase64Url(digest.bytes).substring(0, 20);
      if (device.yuid != expectedYuid) {
        throw const FormatException('Media device YUID does not match.');
      }
      final message = utf8.encode(
        'yappa-media-device-v1|$serverId|${device.authorizedUsername}|'
        '${device.authorizationNonce}|${device.publicKey}|${device.id}',
      );
      final verified = await _signatures.verify(
        message: message,
        signature: authorization,
        publicKey: yuidPublicKey,
      );
      if (!verified) {
        throw const FormatException('Media device authorization is invalid.');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid media device key encoding.');
    }
  }

  Uint8List _decodeBase64Url(String value) {
    final padding = (4 - value.length % 4) % 4;
    return Uint8List.fromList(
      base64Url.decode(value.padRight(value.length + padding, '=')),
    );
  }

  String _encodeBase64Url(List<int> value) =>
      base64Url.encode(value).replaceAll('=', '');

  bool _sameStrings(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index += 1) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}
