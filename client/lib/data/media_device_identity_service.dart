import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secret_storage.dart';

class MediaDeviceIdentity {
  final String deviceId;
  final String publicKeyBase64Url;
  final String privateKeyBase64Url;

  const MediaDeviceIdentity({
    required this.deviceId,
    required this.publicKeyBase64Url,
    required this.privateKeyBase64Url,
  });
}

class MediaDeviceIdentityService {
  static const _secureIdentityKey = 'yappa.media_device_identity.v1';

  final SecretStorage _secretStorage;
  final X25519 _algorithm = X25519();
  MediaDeviceIdentity? _cached;

  MediaDeviceIdentityService({
    SecretStorage secretStorage = const OsSecretStorage(),
  }) : _secretStorage = secretStorage;

  Future<MediaDeviceIdentity> getOrCreateIdentity() async {
    if (_cached != null) return _cached!;
    final stored = await _readIdentity();
    if (stored != null && await _isValid(stored)) {
      _cached = stored;
      return stored;
    }

    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final randomId = await SecretKeyData.random(length: 18).extractBytes();
    final created = MediaDeviceIdentity(
      deviceId: 'device_${_base64UrlNoPadding(randomId)}',
      publicKeyBase64Url: _base64UrlNoPadding(publicKey.bytes),
      privateKeyBase64Url: _base64UrlNoPadding(privateKey),
    );
    await _saveIdentity(created);
    _cached = created;
    return created;
  }

  Future<SimpleKeyPairData> keyPair() async {
    final identity = await getOrCreateIdentity();
    return SimpleKeyPairData(
      _decodeBase64Url(identity.privateKeyBase64Url),
      publicKey: SimplePublicKey(
        _decodeBase64Url(identity.publicKeyBase64Url),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
  }

  Future<bool> _isValid(MediaDeviceIdentity identity) async {
    if (!RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(identity.deviceId)) {
      return false;
    }
    try {
      final keyPair = SimpleKeyPairData(
        _decodeBase64Url(identity.privateKeyBase64Url),
        publicKey: SimplePublicKey(
          _decodeBase64Url(identity.publicKeyBase64Url),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
      final derived = await keyPair.extractPublicKey();
      return _constantTimeEquals(
        derived.bytes,
        _decodeBase64Url(identity.publicKeyBase64Url),
      );
    } catch (_) {
      return false;
    }
  }

  Future<MediaDeviceIdentity?> _readIdentity() async {
    final raw = await _secretStorage.read(_secureIdentityKey);
    if ((raw ?? '').isEmpty) return null;
    try {
      final decoded = jsonDecode(raw!);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final identity = MediaDeviceIdentity(
        deviceId: map['deviceId']?.toString() ?? '',
        publicKeyBase64Url: map['publicKeyBase64Url']?.toString() ?? '',
        privateKeyBase64Url: map['privateKeyBase64Url']?.toString() ?? '',
      );
      if (identity.deviceId.isEmpty ||
          identity.publicKeyBase64Url.isEmpty ||
          identity.privateKeyBase64Url.isEmpty) {
        return null;
      }
      return identity;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveIdentity(MediaDeviceIdentity identity) {
    return _secretStorage.write(
      _secureIdentityKey,
      jsonEncode({
        'version': 1,
        'deviceId': identity.deviceId,
        'publicKeyBase64Url': identity.publicKeyBase64Url,
        'privateKeyBase64Url': identity.privateKeyBase64Url,
      }),
    );
  }

  String _base64UrlNoPadding(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  List<int> _decodeBase64Url(String value) {
    final normalized = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    return base64Url.decode(normalized);
  }

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index += 1) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }
}
