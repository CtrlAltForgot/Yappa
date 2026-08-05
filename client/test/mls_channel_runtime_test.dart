import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/media_device_identity_service.dart';
import 'package:yappa/data/mls_channel_runtime.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_native.dart';
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

class _RuntimeApi extends ApiClient {
  String deviceId = '';
  List<MlsDeviceCredential> credentials = const [];
  int initializeCalls = 0;
  bool createInitialization = true;

  @override
  Future<MlsKeyPackageInventory> fetchMlsKeyPackageInventory({
    required String baseUrl,
    required String token,
  }) async =>
      MlsKeyPackageInventory(deviceId: deviceId, total: 10, available: 10);

  @override
  Future<List<MlsDeviceCredential>> fetchMlsDeviceCredentials({
    required String baseUrl,
    required String token,
  }) async => credentials;

  @override
  Future<MlsDeliveryBatch> fetchMlsDeliveryMessages({
    required String baseUrl,
    required String token,
    required String serverId,
    required String channelId,
    required int after,
    int limit = 100,
  }) async => MlsDeliveryBatch(
    group: MlsChannelGroup(
      groupId: 'yappa-text-v1|$serverId|$channelId',
      currentEpoch: 0,
      nextSequence: 1,
      initializedByDeviceId: initializeCalls == 0 ? null : deviceId,
      initializedAt: initializeCalls == 0 ? null : DateTime.utc(2026),
    ),
    messages: const [],
    deliveredSequence: after,
  );

  @override
  Future<MlsChannelInitialization> initializeMlsChannel({
    required String baseUrl,
    required String token,
    required String serverId,
    required String channelId,
  }) async {
    initializeCalls += 1;
    return MlsChannelInitialization(
      created: createInitialization,
      group: MlsChannelGroup(
        groupId: 'yappa-text-v1|$serverId|$channelId',
        currentEpoch: 0,
        nextSequence: 1,
        initializedByDeviceId: deviceId,
        initializedAt: DateTime.utc(2026),
      ),
    );
  }

  @override
  Future<MlsDeliveryAcknowledgement> acknowledgeMlsDelivery({
    required String baseUrl,
    required String token,
    required String channelId,
    required int acknowledgedSequence,
    required int acknowledgedEpoch,
  }) async => MlsDeliveryAcknowledgement(
    deliveredSequence: acknowledgedSequence,
    acknowledgedSequence: acknowledgedSequence,
    acknowledgedEpoch: acknowledgedEpoch,
  );
}

Uint8List _decode(String value) => Uint8List.fromList(
  base64Url.decode(
    value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsNative =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test(
    'owner creates only newly allocated state and persists founder cursor',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('yappa-mls-runtime-');
      addTearDown(() => root.delete(recursive: true));
      final secrets = _MemorySecrets();
      final media = MediaDeviceIdentityService(secretStorage: secrets);
      final yuid = YuidIdentityService(secretStorage: secrets);
      final api = _RuntimeApi();
      final runtime = await MlsServerRuntime.open(
        api: api,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        secretStorage: secrets,
        mediaDeviceIdentity: media,
        yuidIdentity: yuid,
        supportDirectory: () async => root,
      );
      addTearDown(runtime.close);
      api.deviceId = runtime.localDevice.deviceId;
      final signatureKey = await runtime.localDevice.read(
        (native) => native.signaturePublicKey,
      );
      final account = await yuid.getOrCreateIdentity();
      final signature = await yuid.signMlsCredentialBinding(
        serverId: 'server-id',
        deviceId: api.deviceId,
        mlsSignaturePublicKey: signatureKey,
      );
      api.credentials = [
        MlsDeviceCredential(
          deviceId: api.deviceId,
          userId: '1',
          username: 'owner',
          yuid: account.yuid,
          yuidPublicKey: _decode(account.publicKeyBase64Url),
          signaturePublicKey: signatureKey,
          identityBindingSignature: _decode(signature),
          isServerOwner: true,
          isActive: true,
          createdAt: DateTime.utc(2026),
        ),
      ];
      final channel = await runtime.openChannel(
        channelId: '1',
        currentUserIsOwner: true,
        secretStorage: secrets,
        eventDirectory: () async => Directory('${root.path}/events'),
      );

      api.createInitialization = false;
      final existing = await channel.synchronize();
      expect(existing.readiness, MlsChannelReadiness.waitingForWelcome);
      await expectLater(
        runtime.localDevice.read(
          (native) => native.epoch(
            Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits),
          ),
        ),
        throwsA(isA<MlsNativeException>()),
      );

      api.createInitialization = true;
      final startup = await channel.synchronize();
      expect(startup.readiness, MlsChannelReadiness.ready);
      expect(api.initializeCalls, 2);
      final cursor = await channel.receive.cursorStore.read();
      expect(cursor.joined, isTrue);
      expect(cursor.sequence, 0);
      expect(cursor.epoch, 0);
    },
    skip: !supportsNative,
  );
}
