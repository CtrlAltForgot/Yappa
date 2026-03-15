import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

class YuidIdentity {
  final String yuid;
  final String publicKeyBase64Url;
  final String privateKeyBase64Url;

  const YuidIdentity({
    required this.yuid,
    required this.publicKeyBase64Url,
    required this.privateKeyBase64Url,
  });
}

class YuidAuthProof {
  final String yuid;
  final String publicKeyBase64Url;
  final String signatureBase64Url;

  const YuidAuthProof({
    required this.yuid,
    required this.publicKeyBase64Url,
    required this.signatureBase64Url,
  });
}

class YuidIdentityService {
  static const _yuidKey = 'yappa_yuid';
  static const _publicKeyKey = 'yappa_yuid_public_key';
  static const _privateKeyKey = 'yappa_yuid_private_key';
  static const int _canonicalYuidLength = 20;

  final Ed25519 _algorithm = Ed25519();
  YuidIdentity? _cached;

  Future<YuidIdentity> getOrCreateIdentity() async {
    if (_cached != null) return _cached!;

    final prefs = await SharedPreferences.getInstance();
    final storedPublic = prefs.getString(_publicKeyKey)?.trim();
    final storedPrivate = prefs.getString(_privateKeyKey)?.trim();

    if ((storedPublic ?? '').isNotEmpty && (storedPrivate ?? '').isNotEmpty) {
      final canonicalYuid = await _buildYuidFromPublicKeyBase64Url(storedPublic!);
      final restored = YuidIdentity(
        yuid: canonicalYuid,
        publicKeyBase64Url: storedPublic,
        privateKeyBase64Url: storedPrivate!,
      );

      final storedYuid = prefs.getString(_yuidKey)?.trim();
      if (storedYuid != canonicalYuid) {
        await prefs.setString(_yuidKey, canonicalYuid);
      }

      _cached = restored;
      return restored;
    }

    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

    final created = YuidIdentity(
      yuid: await _buildYuidFromPublicKeyBytes(publicKey.bytes),
      publicKeyBase64Url: _base64UrlNoPad(publicKey.bytes),
      privateKeyBase64Url: _base64UrlNoPad(privateKeyBytes),
    );

    await prefs.setString(_yuidKey, created.yuid);
    await prefs.setString(_publicKeyKey, created.publicKeyBase64Url);
    await prefs.setString(_privateKeyKey, created.privateKeyBase64Url);
    _cached = created;
    return created;
  }

  Future<YuidAuthProof> buildAuthProof({
    required String serverId,
    required String username,
    required String nonce,
  }) async {
    final identity = await getOrCreateIdentity();
    final normalizedUsername = username.trim().toLowerCase();
    final message = utf8.encode(
      'yappa-auth-v1|$serverId|$normalizedUsername|$nonce',
    );

    final publicKey = SimplePublicKey(
      _decodeBase64Url(identity.publicKeyBase64Url),
      type: KeyPairType.ed25519,
    );
    final keyPair = SimpleKeyPairData(
      _decodeBase64Url(identity.privateKeyBase64Url),
      publicKey: publicKey,
      type: KeyPairType.ed25519,
    );
    final signature = await _algorithm.sign(message, keyPair: keyPair);

    return YuidAuthProof(
      yuid: identity.yuid,
      publicKeyBase64Url: identity.publicKeyBase64Url,
      signatureBase64Url: _base64UrlNoPad(signature.bytes),
    );
  }

  Future<String> _buildYuidFromPublicKeyBase64Url(String value) async {
    return _buildYuidFromPublicKeyBytes(_decodeBase64Url(value));
  }

  Future<String> _buildYuidFromPublicKeyBytes(List<int> publicKeyBytes) async {
    final digest = await Sha256().hash(publicKeyBytes);
    final encoded = _base64UrlNoPad(digest.bytes);
    return encoded.substring(0, _canonicalYuidLength);
  }

  String _base64UrlNoPad(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Uint8List _decodeBase64Url(String value) {
    final normalized = value.trim();
    final padding = (4 - normalized.length % 4) % 4;
    return Uint8List.fromList(
      base64Url.decode(normalized.padRight(normalized.length + padding, '=')),
    );
  }
}
