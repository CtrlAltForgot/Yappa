import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/media_room_state.dart';

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Future<MediaDevicePublicIdentity> _device({
  required String serverId,
  required String id,
  required String username,
}) async {
  final signing = Ed25519();
  final yuidKeys = await signing.newKeyPair();
  final yuidPublic = await yuidKeys.extractPublicKey();
  final mediaPublic = await X25519().newKeyPair().then(
    (keyPair) => keyPair.extractPublicKey(),
  );
  final yuidDigest = await Sha256().hash(yuidPublic.bytes);
  final yuid = _encode(yuidDigest.bytes).substring(0, 20);
  final publicKey = _encode(mediaPublic.bytes);
  const nonce = 'AAAAAAAAAAAAAAAAAAAAAA';
  final authorization = await signing.sign(
    utf8.encode(
      'yappa-media-device-v1|$serverId|$username|$nonce|$publicKey|$id',
    ),
    keyPair: yuidKeys,
  );
  return MediaDevicePublicIdentity(
    id: id,
    userId: id.endsWith('A') ? '1' : '2',
    publicKey: publicKey,
    yuidAuthorizationSignature: _encode(authorization.bytes),
    authorizationNonce: nonce,
    authorizedUsername: username,
    username: username,
    yuid: yuid,
    yuidPublicKey: _encode(yuidPublic.bytes),
  );
}

void main() {
  test(
    'accepts sorted room membership with YUID-authorized device keys',
    () async {
      const serverId = 'node_security_test';
      const channelId = '7';
      final first = await _device(
        serverId: serverId,
        id: 'device_AAAAAAAAAAAAAAAAAAAAAAAA',
        username: 'first',
      );
      final second = await _device(
        serverId: serverId,
        id: 'device_BBBBBBBBBBBBBBBBBBBBBBBB',
        username: 'second',
      );
      final state = MediaRoomState(
        protocol: 'yappa-media-room-v1',
        serverId: serverId,
        channelId: channelId,
        epoch: 2,
        membershipSequence: 3,
        leaderDeviceId: first.id,
        devices: [first, second],
      );

      await MediaRoomStateVerifier().verify(
        state,
        expectedServerId: serverId,
        expectedChannelId: channelId,
        minimumEpoch: 2,
        minimumMembershipSequence: 3,
      );
    },
  );

  test('rejects substituted keys, wrong leaders, and stale state', () async {
    const serverId = 'node_security_test';
    final device = await _device(
      serverId: serverId,
      id: 'device_AAAAAAAAAAAAAAAAAAAAAAAA',
      username: 'first',
    );
    final substituted = MediaDevicePublicIdentity(
      id: device.id,
      userId: device.userId,
      publicKey: _encode(
        (await (await X25519().newKeyPair()).extractPublicKey()).bytes,
      ),
      yuidAuthorizationSignature: device.yuidAuthorizationSignature,
      authorizationNonce: device.authorizationNonce,
      authorizedUsername: device.authorizedUsername,
      username: device.username,
      yuid: device.yuid,
      yuidPublicKey: device.yuidPublicKey,
    );

    final substitutedState = MediaRoomState(
      protocol: 'yappa-media-room-v1',
      serverId: serverId,
      channelId: '7',
      epoch: 2,
      membershipSequence: 2,
      leaderDeviceId: device.id,
      devices: [substituted],
    );
    final wrongLeaderState = MediaRoomState(
      protocol: 'yappa-media-room-v1',
      serverId: serverId,
      channelId: '7',
      epoch: 2,
      membershipSequence: 2,
      leaderDeviceId: 'device_BBBBBBBBBBBBBBBBBBBBBBBB',
      devices: [device],
    );
    final staleState = MediaRoomState(
      protocol: 'yappa-media-room-v1',
      serverId: serverId,
      channelId: '7',
      epoch: 1,
      membershipSequence: 1,
      leaderDeviceId: device.id,
      devices: [device],
    );
    for (final state in [substitutedState, wrongLeaderState]) {
      await expectLater(
        MediaRoomStateVerifier().verify(
          state,
          expectedServerId: serverId,
          expectedChannelId: '7',
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      MediaRoomStateVerifier().verify(
        staleState,
        expectedServerId: serverId,
        expectedChannelId: '7',
        minimumEpoch: 2,
        minimumMembershipSequence: 2,
      ),
      throwsFormatException,
    );
  });
}
