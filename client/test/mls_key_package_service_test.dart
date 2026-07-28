import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_key_package_service.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_native.dart';
import 'package:yappa/data/secret_storage.dart';
import 'package:yappa/data/yuid_identity_service.dart';

class MemorySecretStorage implements SecretStorage {
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

class _CredentialApi extends ApiClient {
  final List<MlsDeviceCredential> credentials;

  _CredentialApi(this.credentials);

  @override
  Future<List<MlsDeviceCredential>> fetchMlsDeviceCredentials({
    required String baseUrl,
    required String token,
  }) async => credentials;
}

Uint8List decodeBase64Url(String value) {
  final normalized = value.padRight(
    value.length + ((4 - value.length % 4) % 4),
    '=',
  );
  return Uint8List.fromList(base64Url.decode(normalized));
}

void main() {
  test('group authorization requires exactly one leaf per intended device', () {
    VerifiedMlsDeviceBinding binding(String deviceId, int marker) =>
        VerifiedMlsDeviceBinding(
          yuid: 'yuid-$marker',
          deviceId: deviceId,
          credential: Uint8List.fromList([marker]),
          signaturePublicKey: Uint8List.fromList(List<int>.filled(32, marker)),
          isServerOwner: marker == 1,
        );
    MlsGroupMember member(VerifiedMlsDeviceBinding binding) => MlsGroupMember(
      credential: binding.credential,
      signaturePublicKey: binding.signaturePublicKey,
    );

    final owner = binding('device_${'a' * 24}', 1);
    final memberDevice = binding('device_${'b' * 24}', 2);
    MlsKeyPackageService.authenticateMembers(
      [member(owner), member(memberDevice)],
      [owner, memberDevice],
    );
    expect(
      () => MlsKeyPackageService.authenticateMembers(
        [member(owner)],
        [owner, memberDevice],
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => MlsKeyPackageService.authenticateMembers(
        [member(owner), member(owner)],
        [owner, memberDevice],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsMlsBridge =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test(
    'claimed KeyPackage requires a valid YUID credential binding',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('yappa-mls-kp-');
      final secrets = MemorySecretStorage();
      final yuid = YuidIdentityService(secretStorage: secrets);
      final local = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: secrets,
        yuidIdentity: yuid,
        supportDirectory: () async => root,
      );
      addTearDown(local.close);
      addTearDown(() => root.delete(recursive: true));

      final signatureKey = await local.read(
        (native) => native.signaturePublicKey,
      );
      final keyPackage = await local.mutate(
        (native) => native.generateKeyPackage(),
      );
      final identity = await yuid.getOrCreateIdentity();
      final binding = decodeBase64Url(
        await yuid.signMlsCredentialBinding(
          serverId: local.serverId,
          deviceId: local.deviceId,
          mlsSignaturePublicKey: signatureKey,
        ),
      );
      final claimed = ClaimedMlsKeyPackage(
        id: 'kp_1234567890123456789012',
        deviceId: local.deviceId,
        ciphersuite: 1,
        signaturePublicKey: signatureKey,
        identityBindingSignature: binding,
        username: 'alice',
        yuid: identity.yuid,
        yuidPublicKey: decodeBase64Url(identity.publicKeyBase64Url),
        keyPackage: keyPackage,
        keyPackageHash: '',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
      final service = MlsKeyPackageService(
        api: ApiClient(),
        localDevice: local,
        yuidIdentity: yuid,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
      );

      final verified = await service.verifyClaimed(claimed);
      expect(verified.binding.signaturePublicKey, signatureKey);
      expect(
        verified.binding.credential,
        MlsLocalDevice.credentialIdentity(
          serverId: local.serverId,
          yuid: identity.yuid,
          deviceId: local.deviceId,
        ),
      );
      await local.mutate(
        (native) => native.createGroup(
          Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits),
        ),
      );
      final directoryService = MlsKeyPackageService(
        api: _CredentialApi([
          MlsDeviceCredential(
            deviceId: local.deviceId,
            userId: '1',
            username: 'alice',
            yuid: identity.yuid,
            yuidPublicKey: decodeBase64Url(identity.publicKeyBase64Url),
            signaturePublicKey: signatureKey,
            identityBindingSignature: binding,
            isServerOwner: true,
            isActive: true,
            createdAt: DateTime.now().toUtc(),
          ),
        ]),
        localDevice: local,
        yuidIdentity: yuid,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
      );
      await directoryService.authenticateGroupMembers(
        Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits),
      );

      final wrongKey = Uint8List.fromList(signatureKey)..[0] ^= 1;
      final unauthorizedService = MlsKeyPackageService(
        api: _CredentialApi([
          MlsDeviceCredential(
            deviceId: local.deviceId,
            userId: '1',
            username: 'alice',
            yuid: identity.yuid,
            yuidPublicKey: decodeBase64Url(identity.publicKeyBase64Url),
            signaturePublicKey: wrongKey,
            identityBindingSignature: binding,
            isServerOwner: true,
            isActive: true,
            createdAt: DateTime.now().toUtc(),
          ),
        ]),
        localDevice: local,
        yuidIdentity: yuid,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
      );
      expect(
        () => unauthorizedService.authenticateGroupMembers(
          Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits),
        ),
        throwsA(isA<FormatException>()),
      );

      final tampered = Uint8List.fromList(binding);
      tampered[0] ^= 1;
      expect(
        () => service.verifyClaimed(
          ClaimedMlsKeyPackage(
            id: claimed.id,
            deviceId: claimed.deviceId,
            ciphersuite: claimed.ciphersuite,
            signaturePublicKey: claimed.signaturePublicKey,
            identityBindingSignature: tampered,
            username: claimed.username,
            yuid: claimed.yuid,
            yuidPublicKey: claimed.yuidPublicKey,
            keyPackage: claimed.keyPackage,
            keyPackageHash: claimed.keyPackageHash,
            expiresAt: claimed.expiresAt,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    },
    skip: !supportsMlsBridge,
  );
}
