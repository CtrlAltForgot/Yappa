import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/mls_key_package_service.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_receive_coordinator.dart';
import 'package:yappa/data/secret_storage.dart';
import 'package:yappa/data/yuid_identity_service.dart';

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

class _ReplayApi extends ApiClient {
  final MlsDeliveryBatch batch;
  MlsDeliveryAcknowledgement? acknowledgement;

  _ReplayApi(this.batch);

  @override
  Future<MlsDeliveryBatch> fetchMlsDeliveryMessages({
    required String baseUrl,
    required String token,
    required String serverId,
    required String channelId,
    required int after,
    int limit = 100,
  }) async => batch;

  @override
  Future<MlsDeliveryAcknowledgement> acknowledgeMlsDelivery({
    required String baseUrl,
    required String token,
    required String channelId,
    required int acknowledgedSequence,
    required int acknowledgedEpoch,
  }) async {
    acknowledgement = MlsDeliveryAcknowledgement(
      deliveredSequence: acknowledgedSequence,
      acknowledgedSequence: acknowledgedSequence,
      acknowledgedEpoch: acknowledgedEpoch,
    );
    return acknowledgement!;
  }
}

class _DirectoryService extends MlsKeyPackageService {
  final List<VerifiedMlsDeviceBinding> directory;

  _DirectoryService({
    required this.directory,
    required super.api,
    required super.localDevice,
    required super.yuidIdentity,
  }) : super(baseUrl: 'http://127.0.0.1:4100', token: 'unused');

  @override
  Future<List<VerifiedMlsDeviceBinding>> fetchVerifiedDirectory() async =>
      directory;
}

MlsDeliveryMessage _message({
  required int sequence,
  required MlsDeliveryMessageClass messageClass,
  required Uint8List wire,
  required int acceptedEpoch,
  int? parentEpoch,
  String? recipient,
}) => MlsDeliveryMessage(
  id: 'mls_${sequence.toString().padLeft(22, 'a')}',
  clientOperationId: 'mlsop_${sequence.toString().padLeft(22, 'b')}',
  channelId: '1',
  serverSequence: sequence,
  messageClass: messageClass,
  acceptedEpoch: acceptedEpoch,
  parentEpoch: parentEpoch,
  uploaderUserId: '1',
  uploaderDeviceId: 'device_${'u' * 24}',
  recipientDeviceId: recipient,
  wireMessage: wire,
  createdAt: DateTime.utc(2026),
  event: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsMlsBridge =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test(
    'recipient skips pre-Welcome commit, verifies tree, and acknowledges',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('yappa-mls-receive-');
      addTearDown(() => root.delete(recursive: true));
      final ownerSecrets = _MemorySecrets();
      final memberSecrets = _MemorySecrets();
      final ownerYuid = YuidIdentityService(secretStorage: ownerSecrets);
      final memberYuid = YuidIdentityService(secretStorage: memberSecrets);
      final owner = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: ownerSecrets,
        yuidIdentity: ownerYuid,
        supportDirectory: () async => Directory('${root.path}/owner'),
      );
      final member = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: memberSecrets,
        yuidIdentity: memberYuid,
        supportDirectory: () async => Directory('${root.path}/member'),
      );
      addTearDown(owner.close);
      addTearDown(member.close);
      final groupId = Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits);
      await owner.mutate((native) => native.createGroup(groupId));
      final keyPackage = await member.mutate(
        (native) => native.generateKeyPackage(),
      );
      final add = await owner.mutate(
        (native) => native.prepareAdd(groupId, keyPackage),
      );
      await owner.mutate((native) => native.acceptPendingCommit(groupId));
      final ownerSignature = await owner.read(
        (native) => native.signaturePublicKey,
      );
      final memberSignature = await member.read(
        (native) => native.signaturePublicKey,
      );
      final directory = [
        VerifiedMlsDeviceBinding(
          yuid: owner.yuid,
          deviceId: owner.deviceId,
          credential: owner.identity,
          signaturePublicKey: ownerSignature,
          isServerOwner: true,
        ),
        VerifiedMlsDeviceBinding(
          yuid: member.yuid,
          deviceId: member.deviceId,
          credential: member.identity,
          signaturePublicKey: memberSignature,
          isServerOwner: false,
        ),
      ];
      final batch = MlsDeliveryBatch(
        group: const MlsChannelGroup(
          groupId: 'yappa-text-v1|server-id|1',
          currentEpoch: 1,
          nextSequence: 3,
        ),
        messages: [
          _message(
            sequence: 1,
            messageClass: MlsDeliveryMessageClass.commit,
            wire: add.commit,
            acceptedEpoch: 1,
            parentEpoch: 0,
          ),
          _message(
            sequence: 2,
            messageClass: MlsDeliveryMessageClass.welcome,
            wire: add.welcome,
            acceptedEpoch: 1,
            recipient: member.deviceId,
          ),
        ],
        deliveredSequence: 2,
      );
      final api = _ReplayApi(batch);
      final eventStore = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: member.deviceId,
        channelId: '1',
        secretStorage: memberSecrets,
        supportDirectory: () async => Directory('${root.path}/member-events'),
      );
      addTearDown(eventStore.close);
      final coordinator = MlsReceiveCoordinator(
        api: api,
        localDevice: member,
        keyPackages: _DirectoryService(
          directory: directory,
          api: api,
          localDevice: member,
          yuidIdentity: memberYuid,
        ),
        cursorStore: MlsReceiveCursorStore(
          serverId: 'server-id',
          deviceId: member.deviceId,
          channelId: '1',
          secretStorage: memberSecrets,
        ),
        eventStore: eventStore,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
      );

      final cursor = await coordinator.synchronize();
      expect(cursor.joined, isTrue);
      expect(cursor.sequence, 2);
      expect(cursor.epoch, 1);
      expect(await member.read((native) => native.epoch(groupId)), 1);
      expect(api.acknowledgement?.acknowledgedSequence, 2);

      final eventId = 'e' * 22;
      final routing = EncryptedApplicationEventRouting(
        eventId: eventId,
        kind: EncryptedApplicationEventKind.message,
      );
      final plaintext = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocol': 'yappa-message-v1',
            'eventId': eventId,
            'channelId': '1',
            'kind': 'message',
            'targetEventId': null,
            'createdAt': '2026-07-24T12:00:00.000Z',
            'body': {'content': 'durably encrypted'},
          }),
        ),
      );
      final applicationWire = await owner.read(
        (native) => native.encryptApplication(groupId, plaintext),
      );
      final applicationBatch = MlsDeliveryBatch(
        group: batch.group,
        messages: [
          MlsDeliveryMessage(
            id: 'mls_${'x' * 22}',
            clientOperationId: 'mlsop_${'y' * 22}',
            channelId: '1',
            serverSequence: 3,
            messageClass: MlsDeliveryMessageClass.application,
            acceptedEpoch: 1,
            parentEpoch: null,
            uploaderUserId: '1',
            uploaderDeviceId: owner.deviceId,
            recipientDeviceId: null,
            wireMessage: applicationWire,
            createdAt: DateTime.utc(2026),
            event: routing,
          ),
        ],
        deliveredSequence: 3,
      );
      final applicationApi = _ReplayApi(applicationBatch);
      final applicationCoordinator = MlsReceiveCoordinator(
        api: applicationApi,
        localDevice: member,
        keyPackages: _DirectoryService(
          directory: directory,
          api: applicationApi,
          localDevice: member,
          yuidIdentity: memberYuid,
        ),
        cursorStore: MlsReceiveCursorStore(
          serverId: 'server-id',
          deviceId: member.deviceId,
          channelId: '1',
          secretStorage: memberSecrets,
        ),
        eventStore: eventStore,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
      );
      final applicationCursor = await applicationCoordinator.synchronize();
      expect(applicationCursor.sequence, 3);
      expect(eventStore.events, hasLength(1));
      expect(eventStore.events.single.body['content'], 'durably encrypted');
      expect(applicationApi.acknowledgement?.acknowledgedSequence, 3);

      final cursorKey = memberSecrets.values.keys.singleWhere(
        (key) => key.startsWith('yappa.mls_receive_cursor.v1.'),
      );
      memberSecrets.values[cursorKey] = jsonEncode({
        'version': 1,
        'sequence': 2,
        'epoch': 1,
        'joined': true,
      });
      final replayCursor = await applicationCoordinator.synchronize();
      expect(replayCursor.sequence, 3);
      expect(eventStore.events, hasLength(1));
    },
    skip: !supportsMlsBridge,
  );
}
