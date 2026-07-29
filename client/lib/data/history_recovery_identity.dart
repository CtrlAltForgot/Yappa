import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secret_storage.dart';

class HistoryRecoveryIdentity {
  final String serverId;
  final String deviceId;
  final String publicKeyBase64Url;
  final String privateKeyBase64Url;

  const HistoryRecoveryIdentity({
    required this.serverId,
    required this.deviceId,
    required this.publicKeyBase64Url,
    required this.privateKeyBase64Url,
  });
}

class HistoryRecoveryIdentityService {
  static const _keyPrefix = 'yappa.history_recovery_identity.v1';

  final SecretStorage _secretStorage;
  final X25519 _algorithm = X25519();
  final Map<String, HistoryRecoveryIdentity> _cache = {};

  HistoryRecoveryIdentityService({
    SecretStorage secretStorage = const OsSecretStorage(),
  }) : _secretStorage = secretStorage;

  Future<HistoryRecoveryIdentity> getOrCreate({
    required String serverId,
    required String deviceId,
  }) async {
    final normalizedServerId = serverId.trim();
    if (normalizedServerId.isEmpty ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId)) {
      throw ArgumentError('Invalid encrypted-history recovery key context.');
    }
    final context = '$normalizedServerId|$deviceId';
    final cached = _cache[context];
    if (cached != null) {
      return cached;
    }
    final stored = await _read(context);
    if (stored != null && await _isValid(stored, context)) {
      _cache[context] = stored;
      return stored;
    }

    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final created = HistoryRecoveryIdentity(
      serverId: normalizedServerId,
      deviceId: deviceId,
      publicKeyBase64Url: _encode(publicKey.bytes),
      privateKeyBase64Url: _encode(await keyPair.extractPrivateKeyBytes()),
    );
    await _secretStorage.write(
      _storageKey(context),
      jsonEncode({
        'version': 1,
        'serverId': created.serverId,
        'deviceId': created.deviceId,
        'publicKeyBase64Url': created.publicKeyBase64Url,
        'privateKeyBase64Url': created.privateKeyBase64Url,
      }),
    );
    _cache[context] = created;
    return created;
  }

  Future<SimpleKeyPairData> keyPair({
    required String serverId,
    required String deviceId,
  }) async {
    final identity = await getOrCreate(serverId: serverId, deviceId: deviceId);
    return SimpleKeyPairData(
      _decode(identity.privateKeyBase64Url),
      publicKey: SimplePublicKey(
        _decode(identity.publicKeyBase64Url),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
  }

  Future<HistoryRecoveryIdentity?> _read(String context) async {
    final raw = await _secretStorage.read(_storageKey(context));
    if ((raw ?? '').isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw!);
      if (decoded is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      return HistoryRecoveryIdentity(
        serverId: map['serverId']?.toString() ?? '',
        deviceId: map['deviceId']?.toString() ?? '',
        publicKeyBase64Url: map['publicKeyBase64Url']?.toString() ?? '',
        privateKeyBase64Url: map['privateKeyBase64Url']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isValid(
    HistoryRecoveryIdentity identity,
    String context,
  ) async {
    if ('${identity.serverId}|${identity.deviceId}' != context ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(identity.publicKeyBase64Url) ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}$',
        ).hasMatch(identity.privateKeyBase64Url)) {
      return false;
    }
    try {
      final keyPair = SimpleKeyPairData(
        _decode(identity.privateKeyBase64Url),
        publicKey: SimplePublicKey(
          _decode(identity.publicKeyBase64Url),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
      final derived = await keyPair.extractPublicKey();
      return _constantTimeEquals(
        derived.bytes,
        _decode(identity.publicKeyBase64Url),
      );
    } catch (_) {
      return false;
    }
  }

  String _storageKey(String context) =>
      '$_keyPrefix.${base64Url.encode(utf8.encode(context)).replaceAll('=', '')}';

  String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  List<int> _decode(String value) {
    final padding = (4 - value.length % 4) % 4;
    return base64Url.decode(value.padRight(value.length + padding, '='));
  }

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < first.length; index += 1) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }
}
