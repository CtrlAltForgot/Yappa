import 'dart:convert';
import 'dart:typed_data';

import 'mls_add_coordinator.dart';
import 'mls_key_package_service.dart';
import 'mls_local_state.dart';

typedef MlsDirectoryLoader = Future<List<VerifiedMlsDeviceBinding>> Function();
typedef MlsKeyPackageClaimer =
    Future<VerifiedMlsKeyPackage> Function(String deviceId);

class MlsMembershipReconciliation {
  final bool isLeader;
  final List<String> addedDeviceIds;
  final List<String> waitingDeviceIds;

  const MlsMembershipReconciliation({
    required this.isLeader,
    required this.addedDeviceIds,
    required this.waitingDeviceIds,
  });

  bool get complete => waitingDeviceIds.isEmpty;
}

class MlsMembershipCoordinator {
  final MlsLocalDevice localDevice;
  final MlsAddCoordinator addCoordinator;
  final MlsDirectoryLoader loadDirectory;
  final MlsKeyPackageClaimer claimKeyPackage;
  final String serverId;
  final String channelId;

  MlsMembershipCoordinator({
    required this.localDevice,
    required this.addCoordinator,
    required this.loadDirectory,
    required this.claimKeyPackage,
    required this.serverId,
    required this.channelId,
  });

  factory MlsMembershipCoordinator.withKeyPackageService({
    required MlsLocalDevice localDevice,
    required MlsAddCoordinator addCoordinator,
    required MlsKeyPackageService keyPackages,
    required String serverId,
    required String channelId,
  }) => MlsMembershipCoordinator(
    localDevice: localDevice,
    addCoordinator: addCoordinator,
    loadDirectory: keyPackages.fetchVerifiedDirectory,
    claimKeyPackage: keyPackages.claimAndVerify,
    serverId: serverId,
    channelId: channelId,
  );

  Uint8List get groupId =>
      Uint8List.fromList(utf8.encode('yappa-text-v1|$serverId|$channelId'));

  static String selectLeader(List<VerifiedMlsDeviceBinding> represented) {
    final leaders =
        represented
            .where((binding) => binding.isServerOwner)
            .map((binding) => binding.deviceId)
            .toSet()
            .toList()
          ..sort();
    if (leaders.isEmpty) {
      throw const FormatException(
        'No represented owner device can reconcile MLS membership.',
      );
    }
    return leaders.first;
  }

  static void authorizeClaim({
    required String expectedDeviceId,
    required VerifiedMlsKeyPackage claimed,
    required List<VerifiedMlsDeviceBinding> directory,
  }) {
    final authorized = directory.any(
      (binding) =>
          binding.deviceId == claimed.binding.deviceId &&
          _sameBytes(binding.credential, claimed.binding.credential) &&
          _sameBytes(
            binding.signaturePublicKey,
            claimed.binding.signaturePublicKey,
          ),
    );
    if (!authorized || claimed.binding.deviceId != expectedDeviceId) {
      throw const FormatException(
        'The claimed KeyPackage is outside channel membership intent.',
      );
    }
  }

  Future<MlsMembershipReconciliation> reconcile() async {
    await addCoordinator.resume(groupId: groupId);
    var directory = await loadDirectory();
    var members = await localDevice.read(
      (native) => native.groupMembers(groupId),
    );
    var represented = MlsKeyPackageService.matchAuthorizedMembers(
      members,
      directory,
    );
    final representedIds = represented
        .map((binding) => binding.deviceId)
        .toSet();
    final waiting =
        directory
            .map((binding) => binding.deviceId)
            .where((deviceId) => !representedIds.contains(deviceId))
            .toSet()
            .toList()
          ..sort();
    final isLeader = selectLeader(represented) == localDevice.deviceId;
    if (!isLeader || waiting.isEmpty) {
      return MlsMembershipReconciliation(
        isLeader: isLeader,
        addedDeviceIds: const [],
        waitingDeviceIds: List.unmodifiable(waiting),
      );
    }

    final added = <String>[];
    for (final deviceId in waiting) {
      final verified = await claimKeyPackage(deviceId);
      authorizeClaim(
        expectedDeviceId: deviceId,
        claimed: verified,
        directory: directory,
      );
      await addCoordinator.add(
        channelId: channelId,
        recipientDeviceId: deviceId,
        groupId: groupId,
        verifiedKeyPackage: verified.claimed.keyPackage,
      );
      added.add(deviceId);
    }

    directory = await loadDirectory();
    members = await localDevice.read((native) => native.groupMembers(groupId));
    MlsKeyPackageService.authenticateMembers(members, directory);
    return MlsMembershipReconciliation(
      isLeader: true,
      addedDeviceIds: List.unmodifiable(added),
      waitingDeviceIds: const [],
    );
  }
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
