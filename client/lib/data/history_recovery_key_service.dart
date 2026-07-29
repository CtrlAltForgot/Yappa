import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'api_client.dart';
import 'history_recovery_identity.dart';
import 'yuid_identity_service.dart';

class VerifiedHistoryRecoveryDeviceKey {
  final String accountYuid;
  final String deviceId;
  final SimplePublicKey publicKey;

  const VerifiedHistoryRecoveryDeviceKey({
    required this.accountYuid,
    required this.deviceId,
    required this.publicKey,
  });
}

class HistoryRecoveryKeyService {
  final ApiClient api;
  final HistoryRecoveryIdentityService recoveryIdentity;
  final YuidIdentityService yuidIdentity;
  final String baseUrl;
  final String token;
  final String serverId;
  final String deviceId;
  final Ed25519 _ed25519 = Ed25519();

  HistoryRecoveryKeyService({
    required this.api,
    required this.recoveryIdentity,
    required this.yuidIdentity,
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.deviceId,
  });

  Future<List<VerifiedHistoryRecoveryDeviceKey>> registerAndVerify() async {
    final localYuid = await yuidIdentity.getOrCreateIdentity();
    final localRecovery = await recoveryIdentity.getOrCreate(
      serverId: serverId,
      deviceId: deviceId,
    );
    final signature = await yuidIdentity.signHistoryRecoveryDeviceBinding(
      serverId: serverId,
      deviceId: deviceId,
      recoveryPublicKey: localRecovery.publicKeyBase64Url,
    );
    await api.registerHistoryRecoveryDeviceKey(
      baseUrl: baseUrl,
      token: token,
      expectedDeviceId: deviceId,
      publicKey: localRecovery.publicKeyBase64Url,
      yuidAuthorizationSignature: signature,
    );

    final directory = await api.fetchHistoryRecoveryDeviceKeys(
      baseUrl: baseUrl,
      token: token,
    );
    if (directory.accountYuid != localYuid.yuid) {
      throw ApiException(
        'The server returned recovery keys for another account.',
        code: 'invalid_history_recovery_response',
      );
    }
    final yuidPublicKey = SimplePublicKey(
      _decode(localYuid.publicKeyBase64Url),
      type: KeyPairType.ed25519,
    );
    final verified = <VerifiedHistoryRecoveryDeviceKey>[];
    final seenDevices = <String>{};
    for (final key in directory.keys) {
      if (!seenDevices.add(key.deviceId)) {
        throw ApiException(
          'The server returned duplicate recovery devices.',
          code: 'invalid_history_recovery_response',
        );
      }
      final message = utf8.encode(
        'yappa-history-recovery-device-v1|$serverId|${localYuid.yuid}|'
        '${key.deviceId}|${key.publicKey}',
      );
      final valid = await _ed25519.verify(
        message,
        signature: Signature(
          _decode(key.yuidAuthorizationSignature),
          publicKey: yuidPublicKey,
        ),
      );
      if (!valid) {
        throw ApiException(
          'An encrypted-history recovery device failed identity verification.',
          code: 'invalid_history_recovery_signature',
        );
      }
      verified.add(
        VerifiedHistoryRecoveryDeviceKey(
          accountYuid: localYuid.yuid,
          deviceId: key.deviceId,
          publicKey: SimplePublicKey(
            _decode(key.publicKey),
            type: KeyPairType.x25519,
          ),
        ),
      );
    }
    final current = verified.where((key) => key.deviceId == deviceId).toList();
    if (current.length != 1 ||
        !_constantTimeEquals(
          current.single.publicKey.bytes,
          _decode(localRecovery.publicKeyBase64Url),
        )) {
      throw ApiException(
        'The server did not preserve this device recovery key.',
        code: 'invalid_history_recovery_response',
      );
    }
    return List.unmodifiable(verified);
  }

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
