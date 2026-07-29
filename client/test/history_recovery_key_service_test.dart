import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/history_recovery_identity.dart';
import 'package:yappa/data/history_recovery_key_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers, verifies, and restores a dedicated recovery key', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = _MemorySecretStorage();
    final yuidService = YuidIdentityService(secretStorage: secrets);
    final yuid = await yuidService.getOrCreateIdentity();
    final recoveryService = HistoryRecoveryIdentityService(
      secretStorage: secrets,
    );
    const serverId = 'srv_history_recovery_test';
    const deviceId = 'device_abcdefghijklmnopqrstuvwx';
    final recovery = await recoveryService.getOrCreate(
      serverId: serverId,
      deviceId: deviceId,
    );
    String? registeredSignature;

    final api = ApiClient(
      clientFactory: (_) => MockClient((request) async {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['publicKey'], recovery.publicKeyBase64Url);
          registeredSignature = body['yuidAuthorizationSignature']?.toString();
          return http.Response(
            jsonEncode({
              'ok': true,
              'created': true,
              'key': {
                'deviceId': deviceId,
                'publicKey': recovery.publicKeyBase64Url,
                'yuidAuthorizationSignature': registeredSignature,
                'createdAt': '2026-07-28T12:00:00.000Z',
                'updatedAt': '2026-07-28T12:00:00.000Z',
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'accountYuid': yuid.yuid,
            'keys': [
              {
                'deviceId': deviceId,
                'publicKey': recovery.publicKeyBase64Url,
                'yuidAuthorizationSignature': registeredSignature,
                'createdAt': '2026-07-28T12:00:00.000Z',
                'updatedAt': '2026-07-28T12:00:00.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final keys = await HistoryRecoveryKeyService(
      api: api,
      recoveryIdentity: recoveryService,
      yuidIdentity: yuidService,
      baseUrl: 'http://127.0.0.1:4100',
      token: 'session-token',
      serverId: serverId,
      deviceId: deviceId,
    ).registerAndVerify();

    expect(keys, hasLength(1));
    expect(keys.single.accountYuid, yuid.yuid);
    expect(keys.single.deviceId, deviceId);
    expect(keys.single.publicKey.bytes, isNotEmpty);
    expect(registeredSignature, hasLength(86));

    final restored = await HistoryRecoveryIdentityService(
      secretStorage: secrets,
    ).getOrCreate(serverId: serverId, deviceId: deviceId);
    expect(restored.publicKeyBase64Url, recovery.publicKeyBase64Url);
    expect(restored.privateKeyBase64Url, recovery.privateKeyBase64Url);

    final otherServer = await HistoryRecoveryIdentityService(
      secretStorage: secrets,
    ).getOrCreate(serverId: 'srv_other', deviceId: deviceId);
    expect(otherServer.publicKeyBase64Url, isNot(recovery.publicKeyBase64Url));
  });
}
