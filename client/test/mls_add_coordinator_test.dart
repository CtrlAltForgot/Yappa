import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/mls_add_coordinator.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_local_state.dart';
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

MlsDeliveryMessage _delivery({
  required String channelId,
  required String operationId,
  required MlsDeliveryMessageClass messageClass,
  required int acceptedEpoch,
  required Uint8List wire,
  int? parentEpoch,
  String? recipientDeviceId,
}) => MlsDeliveryMessage(
  id: 'mls_${'z' * 22}',
  clientOperationId: operationId,
  channelId: channelId,
  serverSequence: 1,
  messageClass: messageClass,
  acceptedEpoch: acceptedEpoch,
  parentEpoch: parentEpoch,
  uploaderUserId: '1',
  uploaderDeviceId: 'device_${'u' * 24}',
  recipientDeviceId: recipientDeviceId,
  wireMessage: wire,
  createdAt: DateTime.utc(2026),
  event: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsMlsBridge =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test('add resumes safely after a lost commit response', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('yappa-mls-add-');
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final owner = await MlsLocalDevice.open(
      serverId: 'server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final member = await MlsLocalDevice.open(
      serverId: 'other-server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    addTearDown(owner.close);
    addTearDown(member.close);
    final groupId = Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits);
    await owner.mutate((native) => native.createGroup(groupId));
    final keyPackage = await member.mutate(
      (native) => native.generateKeyPackage(),
    );
    final outbox = await MlsOutbox.open(
      serverId: owner.serverId,
      deviceId: owner.deviceId,
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    addTearDown(outbox.close);
    var loseFirstCommitResponse = true;
    final submittedOperations = <String>[];
    final coordinator = MlsAddCoordinator(
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
          }) async {
            submittedOperations.add(clientOperationId);
            if (messageClass == MlsDeliveryMessageClass.commit &&
                loseFirstCommitResponse) {
              loseFirstCommitResponse = false;
              throw ApiException('Connection lost.');
            }
            return _delivery(
              channelId: channelId,
              operationId: clientOperationId,
              messageClass: messageClass,
              acceptedEpoch: acceptedEpoch,
              wire: wireMessage,
              parentEpoch: parentEpoch,
              recipientDeviceId: recipientDeviceId,
            );
          },
    );

    await expectLater(
      coordinator.add(
        channelId: '1',
        recipientDeviceId: 'device_${'r' * 24}',
        groupId: groupId,
        verifiedKeyPackage: keyPackage,
      ),
      throwsA(isA<ApiException>()),
    );
    final pending = await outbox.read();
    expect(pending?.stage, MlsAddOutboxStage.commitPending);
    expect(await coordinator.resume(groupId: groupId), isTrue);
    expect(await owner.read((native) => native.epoch(groupId)), 1);
    expect(await outbox.read(), isNull);
    expect(submittedOperations[0], submittedOperations[1]);
    expect(submittedOperations.toSet(), hasLength(2));
  }, skip: !supportsMlsBridge);
}
