import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/media_device_identity_service.dart';
import 'package:yappa/data/media_e2ee_coordinator.dart';
import 'package:yappa/data/media_key_envelope.dart';
import 'package:yappa/data/media_room_state.dart';
import 'package:yappa/data/secret_storage.dart';
import 'package:yappa/data/yuid_identity_service.dart';

class _MemorySecretStorage implements SecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

Future<MediaDevicePublicIdentity> _publicIdentity({
  required String serverId,
  required String username,
  required String nonce,
  required MediaDeviceIdentityService deviceService,
  required YuidIdentityService yuidService,
}) async {
  final device = await deviceService.getOrCreateIdentity();
  final yuid = await yuidService.getOrCreateIdentity();
  final authorization = await yuidService.signMediaDeviceAuthorization(
    serverId: serverId,
    username: username,
    nonce: nonce,
    deviceId: device.deviceId,
    mediaPublicKey: device.publicKeyBase64Url,
  );
  return MediaDevicePublicIdentity(
    id: device.deviceId,
    userId: username,
    publicKey: device.publicKeyBase64Url,
    yuidAuthorizationSignature: authorization,
    authorizationNonce: nonce,
    authorizedUsername: username,
    username: username,
    yuid: yuid.yuid,
    yuidPublicKey: yuid.publicKeyBase64Url,
  );
}

Future<MediaE2eeSessionKey> _waitForEpoch(
  MediaE2eeCoordinator coordinator,
  int epoch,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final key = coordinator.sessionKey;
    if (key != null && key.epoch == epoch) return key;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Coordinator did not reach epoch $epoch.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two verified devices share and rotate a client-owned room key',
    () async {
      SharedPreferences.setMockInitialValues({});
      const serverId = 'node_coordinator_test';
      const channelId = '7';
      final firstDeviceService = MediaDeviceIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final secondDeviceService = MediaDeviceIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final firstYuidService = YuidIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final secondYuidService = YuidIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final firstPublic = await _publicIdentity(
        serverId: serverId,
        username: 'first',
        nonce: 'AAAAAAAAAAAAAAAAAAAAAA',
        deviceService: firstDeviceService,
        yuidService: firstYuidService,
      );
      final secondPublic = await _publicIdentity(
        serverId: serverId,
        username: 'second',
        nonce: 'BBBBBBBBBBBBBBBBBBBBBB',
        deviceService: secondDeviceService,
        yuidService: secondYuidService,
      );

      late MediaE2eeCoordinator first;
      late MediaE2eeCoordinator second;
      final errors = <Object>[];
      final installedEpochs = <int>[];
      Future<void> deliver(MediaKeyEnvelope envelope) async {
        if (envelope.recipientDeviceId == firstPublic.id) {
          first.handleEnvelope(envelope);
        } else if (envelope.recipientDeviceId == secondPublic.id) {
          second.handleEnvelope(envelope);
        } else {
          throw StateError('Unknown test recipient.');
        }
      }

      first = MediaE2eeCoordinator(
        deviceIdentity: firstDeviceService,
        yuidIdentity: firstYuidService,
        sendEnvelope: deliver,
        onKeyChanged: (key, _) async => installedEpochs.add(key.epoch),
        onKeyUnavailable: (_, _) async {},
        onError: errors.add,
        onStatusChanged: (_) {},
      );
      second = MediaE2eeCoordinator(
        deviceIdentity: secondDeviceService,
        yuidIdentity: secondYuidService,
        sendEnvelope: deliver,
        onKeyChanged: (key, _) async => installedEpochs.add(key.epoch),
        onKeyUnavailable: (_, _) async {},
        onError: errors.add,
        onStatusChanged: (_) {},
      );
      await first.begin(serverId: serverId, channelId: channelId);
      await second.begin(serverId: serverId, channelId: channelId);

      final devices = [firstPublic, secondPublic]
        ..sort((first, second) => first.id.compareTo(second.id));
      final state = MediaRoomState(
        protocol: 'yappa-media-room-v1',
        serverId: serverId,
        channelId: channelId,
        epoch: 1,
        membershipSequence: 1,
        leaderDeviceId: devices.first.id,
        devices: devices,
      );
      first.handleRoomState(state);
      second.handleRoomState(state);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(errors, isEmpty);
      final firstKey = await first.waitForKey();
      final secondKey = await second.waitForKey();
      expect(firstKey.bytes, secondKey.bytes);
      expect(firstKey.keyIndex, 1);
      expect(errors, isEmpty);

      final remaining = devices.first.id == firstPublic.id ? first : second;
      final removed = devices.first.id == firstPublic.id ? second : first;
      final previousBytes = [...remaining.sessionKey!.bytes];
      removed.end();
      remaining.handleRoomState(
        MediaRoomState(
          protocol: 'yappa-media-room-v1',
          serverId: serverId,
          channelId: channelId,
          epoch: 2,
          membershipSequence: 2,
          leaderDeviceId: devices.first.id,
          devices: [devices.first],
        ),
      );
      final rotatedKey = await _waitForEpoch(remaining, 2);
      expect(rotatedKey.bytes, isNot(equals(previousBytes)));
      expect(rotatedKey.keyIndex, 2);
      expect(installedEpochs, containsAll(<int>[1, 2]));
      expect(errors, isEmpty);

      remaining.end();
    },
  );

  test('leaving a room cancels an in-flight key installation', () async {
    SharedPreferences.setMockInitialValues({});
    const serverId = 'node_generation_test';
    const channelId = '9';
    final deviceService = MediaDeviceIdentityService(
      secretStorage: _MemorySecretStorage(),
    );
    final yuidService = YuidIdentityService(
      secretStorage: _MemorySecretStorage(),
    );
    final publicIdentity = await _publicIdentity(
      serverId: serverId,
      username: 'leader',
      nonce: 'CCCCCCCCCCCCCCCCCCCCCC',
      deviceService: deviceService,
      yuidService: yuidService,
    );
    final quarantineStarted = Completer<void>();
    final releaseQuarantine = Completer<void>();
    final installedKeys = <MediaE2eeSessionKey>[];
    final errors = <Object>[];
    final coordinator = MediaE2eeCoordinator(
      deviceIdentity: deviceService,
      yuidIdentity: yuidService,
      sendEnvelope: (_) async {},
      onKeyChanged: (key, _) async => installedKeys.add(key),
      onKeyUnavailable: (_, _) async {
        quarantineStarted.complete();
        await releaseQuarantine.future;
      },
      onError: errors.add,
      onStatusChanged: (_) {},
    );
    await coordinator.begin(serverId: serverId, channelId: channelId);
    coordinator.handleRoomState(
      MediaRoomState(
        protocol: 'yappa-media-room-v1',
        serverId: serverId,
        channelId: channelId,
        epoch: 1,
        membershipSequence: 1,
        leaderDeviceId: publicIdentity.id,
        devices: [publicIdentity],
      ),
    );
    await quarantineStarted.future;

    coordinator.end();
    releaseQuarantine.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(coordinator.status, MediaE2eeStatus.idle);
    expect(coordinator.sessionKey, isNull);
    expect(installedKeys, isEmpty);
    expect(errors, isEmpty);
  });

  test(
    'coordination failure clears keys and invokes fail-closed quarantine',
    () async {
      SharedPreferences.setMockInitialValues({});
      const serverId = 'node_failure_test';
      const channelId = '11';
      final deviceService = MediaDeviceIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final yuidService = YuidIdentityService(
        secretStorage: _MemorySecretStorage(),
      );
      final publicIdentity = await _publicIdentity(
        serverId: serverId,
        username: 'failureleader',
        nonce: 'DDDDDDDDDDDDDDDDDDDDDD',
        deviceService: deviceService,
        yuidService: yuidService,
      );
      final errors = <Object>[];
      var quarantines = 0;
      final coordinator = MediaE2eeCoordinator(
        deviceIdentity: deviceService,
        yuidIdentity: yuidService,
        sendEnvelope: (_) async {},
        onKeyChanged: (_, _) async {},
        onKeyUnavailable: (_, _) async {
          quarantines += 1;
        },
        onError: errors.add,
        onStatusChanged: (_) {},
      );
      await coordinator.begin(serverId: serverId, channelId: channelId);
      coordinator.handleRoomState(
        MediaRoomState(
          protocol: 'yappa-media-room-v1',
          serverId: serverId,
          channelId: channelId,
          epoch: 1,
          membershipSequence: 1,
          leaderDeviceId: publicIdentity.id,
          devices: [publicIdentity],
        ),
      );
      for (var attempt = 0; attempt < 100; attempt += 1) {
        if (coordinator.status == MediaE2eeStatus.encrypted ||
            coordinator.status == MediaE2eeStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(errors, isEmpty, reason: errors.join('\n'));
      final installed = await coordinator.waitForKey();
      expect(installed.bytes, isNot(everyElement(0)));
      expect(quarantines, 1);

      coordinator.handleRoomState(
        MediaRoomState(
          protocol: 'yappa-media-room-v1',
          serverId: serverId,
          channelId: channelId,
          epoch: 1,
          membershipSequence: 0,
          leaderDeviceId: publicIdentity.id,
          devices: [publicIdentity],
        ),
      );
      for (var attempt = 0; attempt < 100; attempt += 1) {
        if (coordinator.status == MediaE2eeStatus.failed) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(coordinator.status, MediaE2eeStatus.failed);
      expect(coordinator.sessionKey, isNull);
      expect(installed.bytes, everyElement(0));
      expect(quarantines, 2);
      expect(errors, isNotEmpty);
      await expectLater(
        coordinator.waitForKey(),
        throwsA(isA<FormatException>()),
      );
      coordinator.end();
    },
  );
}
