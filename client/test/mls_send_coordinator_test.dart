import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_send_coordinator.dart';
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

class _LostResponseApi extends ApiClient {
  bool loseFirstResponse = true;
  final List<String> operationIds = [];
  final List<Uint8List> wires = [];

  @override
  Future<MlsDeliveryMessage> submitMlsDeliveryMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String clientOperationId,
    required MlsDeliveryMessageClass messageClass,
    required int acceptedEpoch,
    required Uint8List wireMessage,
    int? parentEpoch,
    String? recipientDeviceId,
    EncryptedApplicationEventRouting? event,
  }) async {
    operationIds.add(clientOperationId);
    wires.add(Uint8List.fromList(wireMessage));
    if (loseFirstResponse) {
      loseFirstResponse = false;
      throw ApiException('Connection lost after acceptance.');
    }
    return MlsDeliveryMessage(
      id: 'mls_${'m' * 22}',
      clientOperationId: clientOperationId,
      channelId: channelId,
      serverSequence: 1,
      messageClass: messageClass,
      acceptedEpoch: acceptedEpoch,
      parentEpoch: parentEpoch,
      uploaderUserId: '1',
      uploaderDeviceId: 'device_${'u' * 24}',
      recipientDeviceId: recipientDeviceId,
      wireMessage: wireMessage,
      createdAt: DateTime.utc(2026),
      event: event,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsMlsBridge = Platform.isLinux || Platform.isWindows;

  test(
    'outgoing application resumes exact ciphertext after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('yappa-mls-send-');
      final secrets = _MemorySecrets();
      addTearDown(() => root.delete(recursive: true));
      var local = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      final groupId = Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits);
      await local.mutate((native) => native.createGroup(groupId));
      final eventStore = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: local.deviceId,
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      addTearDown(eventStore.close);
      final api = _LostResponseApi();
      var sender = MlsSendCoordinator(
        api: api,
        localDevice: local,
        eventStore: eventStore,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
        senderIsOwner: true,
      );

      await expectLater(
        sender.send(
          kind: EncryptedApplicationEventKind.message,
          body: const {'content': 'survives the crash'},
          createdAt: DateTime.utc(2026, 7, 24),
        ),
        throwsA(isA<ApiException>()),
      );
      expect(
        await local.read((native) => native.pendingOutgoingApplications()),
        hasLength(1),
      );
      await local.close();

      local = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      addTearDown(local.close);
      sender = MlsSendCoordinator(
        api: api,
        localDevice: local,
        eventStore: eventStore,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
        senderIsOwner: true,
      );
      final delivered = await sender.resumePending();

      expect(delivered, hasLength(1));
      expect(api.operationIds[0], api.operationIds[1]);
      expect(api.wires[0], api.wires[1]);
      expect(
        await local.read((native) => native.pendingOutgoingApplications()),
        isEmpty,
      );
      expect(eventStore.events.single.body['content'], 'survives the crash');
    },
    skip: !supportsMlsBridge,
  );
}
