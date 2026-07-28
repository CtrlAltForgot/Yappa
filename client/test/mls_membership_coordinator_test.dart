import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/mls_add_coordinator.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_key_package_service.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_membership_coordinator.dart';
import 'package:yappa/data/mls_outbox.dart';
import 'package:yappa/data/secret_storage.dart';

class _MemorySecrets implements SecretStorage {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsNative =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test('leader and claimed package must match verified membership intent', () {
    VerifiedMlsDeviceBinding binding(String deviceId, int marker, bool owner) =>
        VerifiedMlsDeviceBinding(
          yuid: 'yuid-$marker',
          deviceId: deviceId,
          credential: Uint8List.fromList([marker]),
          signaturePublicKey: Uint8List.fromList(List<int>.filled(32, marker)),
          isServerOwner: owner,
        );
    final ownerA = binding('device_${'b' * 24}', 1, true);
    final ownerB = binding('device_${'a' * 24}', 2, true);
    final member = binding('device_${'c' * 24}', 3, false);
    expect(
      MlsMembershipCoordinator.selectLeader([ownerA, ownerB]),
      ownerB.deviceId,
    );
    expect(
      () => MlsMembershipCoordinator.selectLeader([member]),
      throwsA(isA<FormatException>()),
    );

    final substituted = VerifiedMlsKeyPackage(
      claimed: ClaimedMlsKeyPackage(
        id: 'mlskp_${'s' * 22}',
        deviceId: member.deviceId,
        ciphersuite: 1,
        signaturePublicKey: Uint8List(32),
        identityBindingSignature: Uint8List(64),
        username: 'member',
        yuid: member.yuid,
        yuidPublicKey: Uint8List(32),
        keyPackage: Uint8List.fromList([1]),
        keyPackageHash: 'a' * 64,
        expiresAt: DateTime.utc(2026, 7, 25),
      ),
      binding: binding(member.deviceId, 4, false),
    );
    expect(
      () => MlsMembershipCoordinator.authorizeClaim(
        expectedDeviceId: member.deviceId,
        claimed: substituted,
        directory: [ownerA, ownerB, member],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'represented owner deterministically adds every enrolled device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'yappa-mls-membership-',
      );
      addTearDown(() => root.delete(recursive: true));
      final owner = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: _MemorySecrets(),
        supportDirectory: () async => Directory('${root.path}/owner'),
      );
      final member = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: _MemorySecrets(),
        supportDirectory: () async => Directory('${root.path}/member'),
      );
      addTearDown(owner.close);
      addTearDown(member.close);
      final groupId = Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits);
      await owner.mutate((native) => native.createGroup(groupId));
      final memberKeyPackage = await member.mutate(
        (native) => native.generateKeyPackage(),
      );
      final ownerSignature = await owner.read(
        (native) => native.signaturePublicKey,
      );
      final memberSignature = await member.read(
        (native) => native.signaturePublicKey,
      );
      final ownerBinding = VerifiedMlsDeviceBinding(
        yuid: owner.yuid,
        deviceId: owner.deviceId,
        credential: owner.identity,
        signaturePublicKey: ownerSignature,
        isServerOwner: true,
      );
      final memberBinding = VerifiedMlsDeviceBinding(
        yuid: member.yuid,
        deviceId: member.deviceId,
        credential: member.identity,
        signaturePublicKey: memberSignature,
        isServerOwner: false,
      );
      final directory = [ownerBinding, memberBinding];
      final claimed = VerifiedMlsKeyPackage(
        claimed: ClaimedMlsKeyPackage(
          id: 'mlskp_${'k' * 22}',
          deviceId: member.deviceId,
          ciphersuite: 1,
          signaturePublicKey: memberSignature,
          identityBindingSignature: Uint8List(64),
          username: 'member',
          yuid: member.yuid,
          yuidPublicKey: Uint8List(32),
          keyPackage: memberKeyPackage,
          keyPackageHash: 'a' * 64,
          expiresAt: DateTime.utc(2026, 7, 25),
        ),
        binding: memberBinding,
      );
      final outbox = await MlsOutbox.open(
        serverId: owner.serverId,
        deviceId: owner.deviceId,
        secretStorage: _MemorySecrets(),
        supportDirectory: () async => Directory('${root.path}/outbox'),
      );
      addTearDown(outbox.close);
      var sequence = 0;
      final add = MlsAddCoordinator(
        localDevice: owner,
        outbox: outbox,
        submit:
            ({
              required channelId,
              required clientOperationId,
              required messageClass,
              required acceptedEpoch,
              required wireMessage,
              parentEpoch,
              recipientDeviceId,
            }) async => MlsDeliveryMessage(
              id: 'mls_${String.fromCharCode(97 + sequence) * 22}',
              clientOperationId: clientOperationId,
              channelId: channelId,
              serverSequence: ++sequence,
              messageClass: messageClass,
              acceptedEpoch: acceptedEpoch,
              parentEpoch: parentEpoch,
              uploaderUserId: '1',
              uploaderDeviceId: owner.deviceId,
              recipientDeviceId: recipientDeviceId,
              wireMessage: wireMessage,
              createdAt: DateTime.utc(2026),
              event: null,
            ),
      );
      final coordinator = MlsMembershipCoordinator(
        localDevice: owner,
        addCoordinator: add,
        loadDirectory: () async => directory,
        claimKeyPackage: (deviceId) async {
          expect(deviceId, member.deviceId);
          return claimed;
        },
        serverId: 'server-id',
        channelId: '1',
      );

      final result = await coordinator.reconcile();
      expect(result.isLeader, isTrue);
      expect(result.complete, isTrue);
      expect(result.addedDeviceIds, [member.deviceId]);
      expect(sequence, 2);
      MlsKeyPackageService.authenticateMembers(
        await owner.read((native) => native.groupMembers(groupId)),
        directory,
      );
    },
    skip: !supportsNative,
  );
}
