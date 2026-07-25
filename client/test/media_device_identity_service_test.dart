import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/media_device_identity_service.dart';
import 'package:yappa/data/secret_storage.dart';

class _MemorySecretStorage implements SecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test(
    'media device identity persists its private key only in secret storage',
    () async {
      final storage = _MemorySecretStorage();
      final firstService = MediaDeviceIdentityService(secretStorage: storage);
      final first = await firstService.getOrCreateIdentity();

      expect(first.deviceId, matches(RegExp(r'^device_[A-Za-z0-9_-]{24}$')));
      expect(first.publicKeyBase64Url, hasLength(43));
      expect(first.privateKeyBase64Url, hasLength(43));
      expect(storage.values, hasLength(1));

      final stored = jsonDecode(storage.values.values.single) as Map;
      expect(stored['deviceId'], first.deviceId);
      expect(stored['publicKeyBase64Url'], first.publicKeyBase64Url);
      expect(stored['privateKeyBase64Url'], first.privateKeyBase64Url);

      final restored = await MediaDeviceIdentityService(
        secretStorage: storage,
      ).getOrCreateIdentity();
      expect(restored.deviceId, first.deviceId);
      expect(restored.publicKeyBase64Url, first.publicKeyBase64Url);
      expect(restored.privateKeyBase64Url, first.privateKeyBase64Url);

      final keyPair = await MediaDeviceIdentityService(
        secretStorage: storage,
      ).keyPair();
      final derivedPublicKey = await keyPair.extractPublicKey();
      expect(
        base64Url.encode(derivedPublicKey.bytes).replaceAll('=', ''),
        first.publicKeyBase64Url,
      );
    },
  );

  test('invalid stored media identity is replaced atomically', () async {
    final storage = _MemorySecretStorage()
      ..values['yappa.media_device_identity.v1'] = jsonEncode({
        'version': 1,
        'deviceId': 'device_invalid',
        'publicKeyBase64Url': 'invalid',
        'privateKeyBase64Url': 'invalid',
      });

    final identity = await MediaDeviceIdentityService(
      secretStorage: storage,
    ).getOrCreateIdentity();

    expect(identity.deviceId, matches(RegExp(r'^device_[A-Za-z0-9_-]{24}$')));
    expect(identity.publicKeyBase64Url, hasLength(43));
    expect(identity.privateKeyBase64Url, hasLength(43));
    expect(storage.values, hasLength(1));
  });
}
