import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage.dart';

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
  static const _secureIdentityKey = 'yappa.yuid_identity.v1';
  static const _stableDirectoryName = 'Yappa';
  static const _stableIdentityFileName = 'yuid_identity.json';
  static const int _canonicalYuidLength = 20;

  final Ed25519 _algorithm = Ed25519();
  final SecretStorage _secretStorage;
  YuidIdentity? _cached;

  YuidIdentityService({SecretStorage secretStorage = const OsSecretStorage()})
    : _secretStorage = secretStorage;

  Future<YuidIdentity> getOrCreateIdentity() async {
    if (_cached != null) return _cached!;

    final prefs = await SharedPreferences.getInstance();

    final secureIdentity = await _readSecureIdentity();
    if (secureIdentity != null) {
      final normalized = await _canonicalizeIdentity(secureIdentity);
      await _savePublicIdentity(prefs, normalized);
      await _removeLegacyPrivateCopies(prefs);
      _cached = normalized;
      return normalized;
    }

    final stableIdentity = await _readStableIdentityFile();
    if (stableIdentity != null) {
      final normalized = await _canonicalizeIdentity(stableIdentity);
      await _saveSecureIdentity(normalized);
      await _savePublicIdentity(prefs, normalized);
      await _removeLegacyPrivateCopies(prefs);
      _cached = normalized;
      return normalized;
    }

    final storedPublic = prefs.getString(_publicKeyKey)?.trim();
    final storedPrivate = prefs.getString(_privateKeyKey)?.trim();

    if ((storedPublic ?? '').isNotEmpty && (storedPrivate ?? '').isNotEmpty) {
      final restored = await _canonicalizeIdentity(
        YuidIdentity(
          yuid: prefs.getString(_yuidKey)?.trim() ?? '',
          publicKeyBase64Url: storedPublic!,
          privateKeyBase64Url: storedPrivate!,
        ),
      );

      await _saveSecureIdentity(restored);
      await _savePublicIdentity(prefs, restored);
      await _removeLegacyPrivateCopies(prefs);
      _cached = restored;
      return restored;
    }

    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

    final created = await _canonicalizeIdentity(
      YuidIdentity(
        yuid: '',
        publicKeyBase64Url: _base64UrlNoPad(publicKey.bytes),
        privateKeyBase64Url: _base64UrlNoPad(privateKeyBytes),
      ),
    );

    await _saveSecureIdentity(created);
    await _savePublicIdentity(prefs, created);
    await _removeLegacyPrivateCopies(prefs);
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

  Future<String> signMediaDeviceAuthorization({
    required String serverId,
    required String username,
    required String nonce,
    required String deviceId,
    required String mediaPublicKey,
  }) async {
    final identity = await getOrCreateIdentity();
    final publicKey = SimplePublicKey(
      _decodeBase64Url(identity.publicKeyBase64Url),
      type: KeyPairType.ed25519,
    );
    final keyPair = SimpleKeyPairData(
      _decodeBase64Url(identity.privateKeyBase64Url),
      publicKey: publicKey,
      type: KeyPairType.ed25519,
    );
    final message = utf8.encode(
      'yappa-media-device-v1|$serverId|${username.trim().toLowerCase()}|'
      '$nonce|$mediaPublicKey|$deviceId',
    );
    final signature = await _algorithm.sign(message, keyPair: keyPair);
    return _base64UrlNoPad(signature.bytes);
  }

  Future<String> signMlsCredentialBinding({
    required String serverId,
    required String deviceId,
    required Uint8List mlsSignaturePublicKey,
  }) async {
    if (serverId.trim().isEmpty ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        mlsSignaturePublicKey.length != 32) {
      throw ArgumentError('Invalid MLS credential binding input.');
    }
    final identity = await getOrCreateIdentity();
    final publicKey = SimplePublicKey(
      _decodeBase64Url(identity.publicKeyBase64Url),
      type: KeyPairType.ed25519,
    );
    final keyPair = SimpleKeyPairData(
      _decodeBase64Url(identity.privateKeyBase64Url),
      publicKey: publicKey,
      type: KeyPairType.ed25519,
    );
    final signatureKey = _base64UrlNoPad(mlsSignaturePublicKey);
    final message = utf8.encode(
      'yappa-mls-credential-v1|${serverId.trim()}|${identity.yuid}|'
      '$deviceId|$signatureKey',
    );
    final signature = await _algorithm.sign(message, keyPair: keyPair);
    return _base64UrlNoPad(signature.bytes);
  }

  Future<String> signHistoryRecoveryDeviceBinding({
    required String serverId,
    required String deviceId,
    required String recoveryPublicKey,
  }) async {
    if (serverId.trim().isEmpty ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(recoveryPublicKey)) {
      throw ArgumentError('Invalid encrypted-history recovery key binding.');
    }
    final identity = await getOrCreateIdentity();
    final signature = await _algorithm.sign(
      utf8.encode(
        'yappa-history-recovery-device-v1|${serverId.trim()}|'
        '${identity.yuid}|$deviceId|$recoveryPublicKey',
      ),
      keyPair: await keyPair(),
    );
    return _base64UrlNoPad(signature.bytes);
  }

  Future<SimpleKeyPairData> keyPair() async {
    final identity = await getOrCreateIdentity();
    return SimpleKeyPairData(
      _decodeBase64Url(identity.privateKeyBase64Url),
      publicKey: SimplePublicKey(
        _decodeBase64Url(identity.publicKeyBase64Url),
        type: KeyPairType.ed25519,
      ),
      type: KeyPairType.ed25519,
    );
  }

  Future<Uint8List> privateKeySeed() async {
    final identity = await getOrCreateIdentity();
    final seed = _decodeBase64Url(identity.privateKeyBase64Url);
    if (seed.length != 32) {
      throw const FormatException('Invalid YUID signing seed.');
    }
    return Uint8List.fromList(seed);
  }

  Future<YuidIdentity> _canonicalizeIdentity(YuidIdentity identity) async {
    final canonicalYuid = await _buildYuidFromPublicKeyBase64Url(
      identity.publicKeyBase64Url,
    );
    return YuidIdentity(
      yuid: canonicalYuid,
      publicKeyBase64Url: identity.publicKeyBase64Url.trim(),
      privateKeyBase64Url: identity.privateKeyBase64Url.trim(),
    );
  }

  Future<void> _savePublicIdentity(
    SharedPreferences prefs,
    YuidIdentity identity,
  ) async {
    await prefs.setString(_yuidKey, identity.yuid);
    await prefs.setString(_publicKeyKey, identity.publicKeyBase64Url);
  }

  Future<YuidIdentity?> _readSecureIdentity() async {
    final raw = await _secretStorage.read(_secureIdentityKey);
    if ((raw ?? '').isEmpty) {
      return null;
    }
    return _decodeIdentity(raw!);
  }

  Future<void> _saveSecureIdentity(YuidIdentity identity) async {
    await _secretStorage.write(
      _secureIdentityKey,
      jsonEncode({
        'version': 1,
        'yuid': identity.yuid,
        'publicKeyBase64Url': identity.publicKeyBase64Url,
        'privateKeyBase64Url': identity.privateKeyBase64Url,
      }),
    );
  }

  YuidIdentity? _decodeIdentity(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final publicKey = (decoded['publicKeyBase64Url'] ?? '').toString().trim();
      final privateKey = (decoded['privateKeyBase64Url'] ?? '')
          .toString()
          .trim();
      if (publicKey.isEmpty || privateKey.isEmpty) {
        return null;
      }
      return YuidIdentity(
        yuid: (decoded['yuid'] ?? '').toString().trim(),
        publicKeyBase64Url: publicKey,
        privateKeyBase64Url: privateKey,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _removeLegacyPrivateCopies(SharedPreferences prefs) async {
    await prefs.remove(_privateKeyKey);
    try {
      final file = await _stableIdentityFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Secure storage already contains the identity. A failed cleanup is
      // retried on the next startup.
    }
  }

  Future<YuidIdentity?> _readStableIdentityFile() async {
    try {
      final file = await _stableIdentityFile();
      if (!await file.exists()) {
        return null;
      }

      return _decodeIdentity(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<File> _stableIdentityFile() async {
    final baseDirectory = _resolveStableBaseDirectory();
    final stableDirectoryPath = _joinPath(baseDirectory, _stableDirectoryName);
    final stableDirectory = Directory(stableDirectoryPath);
    if (!await stableDirectory.exists()) {
      await stableDirectory.create(recursive: true);
    }
    return File(_joinPath(stableDirectory.path, _stableIdentityFileName));
  }

  String _resolveStableBaseDirectory() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA']?.trim();
      if ((appData ?? '').isNotEmpty) {
        return appData!;
      }

      final userProfile = Platform.environment['USERPROFILE']?.trim();
      if ((userProfile ?? '').isNotEmpty) {
        return _joinPath(_joinPath(userProfile!, 'AppData'), 'Roaming');
      }
    }

    final home = Platform.environment['HOME']?.trim();
    if (Platform.isMacOS && (home ?? '').isNotEmpty) {
      return _joinPath(_joinPath(home!, 'Library'), 'Application Support');
    }

    if (Platform.isLinux) {
      final xdgConfigHome = Platform.environment['XDG_CONFIG_HOME']?.trim();
      if ((xdgConfigHome ?? '').isNotEmpty) {
        return xdgConfigHome!;
      }
      if ((home ?? '').isNotEmpty) {
        return _joinPath(home!, '.config');
      }
    }

    if ((home ?? '').isNotEmpty) {
      return home!;
    }

    return Directory.current.path;
  }

  String _joinPath(String left, String right) {
    if (left.endsWith(Platform.pathSeparator)) {
      return '$left$right';
    }
    return '$left${Platform.pathSeparator}$right';
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
