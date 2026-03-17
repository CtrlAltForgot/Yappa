import 'dart:convert';
import 'dart:io';
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
  static const _stableDirectoryName = 'Yappa';
  static const _stableIdentityFileName = 'yuid_identity.json';
  static const int _canonicalYuidLength = 20;

  final Ed25519 _algorithm = Ed25519();
  YuidIdentity? _cached;

  Future<YuidIdentity> getOrCreateIdentity() async {
    if (_cached != null) return _cached!;

    final prefs = await SharedPreferences.getInstance();

    final stableIdentity = await _readStableIdentityFile();
    if (stableIdentity != null) {
      final normalized = await _canonicalizeIdentity(stableIdentity);
      await _saveToSharedPreferences(prefs, normalized);
      await _writeStableIdentityFile(normalized);
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

      await _saveToSharedPreferences(prefs, restored);
      await _writeStableIdentityFile(restored);
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

    await _saveToSharedPreferences(prefs, created);
    await _writeStableIdentityFile(created);
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

  Future<void> _saveToSharedPreferences(
    SharedPreferences prefs,
    YuidIdentity identity,
  ) async {
    await prefs.setString(_yuidKey, identity.yuid);
    await prefs.setString(_publicKeyKey, identity.publicKeyBase64Url);
    await prefs.setString(_privateKeyKey, identity.privateKeyBase64Url);
  }

  Future<YuidIdentity?> _readStableIdentityFile() async {
    try {
      final file = await _stableIdentityFile();
      if (!await file.exists()) {
        return null;
      }

      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final publicKey = (decoded['publicKeyBase64Url'] ?? '').toString().trim();
      final privateKey =
          (decoded['privateKeyBase64Url'] ?? '').toString().trim();
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

  Future<void> _writeStableIdentityFile(YuidIdentity identity) async {
    try {
      final file = await _stableIdentityFile();
      await file.parent.create(recursive: true);
      final payload = jsonEncode({
        'version': 1,
        'yuid': identity.yuid,
        'publicKeyBase64Url': identity.publicKeyBase64Url,
        'privateKeyBase64Url': identity.privateKeyBase64Url,
      });
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // Keep auth working even if the stable backup file could not be written.
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
        return _joinPath(
          _joinPath(userProfile!, 'AppData'),
          'Roaming',
        );
      }
    }

    final home = Platform.environment['HOME']?.trim();
    if (Platform.isMacOS && (home ?? '').isNotEmpty) {
      return _joinPath(
        _joinPath(home!, 'Library'),
        'Application Support',
      );
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
