import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'api_client.dart';
import 'mls_delivery_models.dart';
import 'mls_local_state.dart';
import 'mls_native.dart';
import 'yuid_identity_service.dart';

class VerifiedMlsDeviceBinding {
  final String yuid;
  final String deviceId;
  final String userId;
  final String username;
  final Uint8List credential;
  final Uint8List signaturePublicKey;
  final bool isServerOwner;

  const VerifiedMlsDeviceBinding({
    required this.yuid,
    required this.deviceId,
    this.userId = '',
    this.username = '',
    required this.credential,
    required this.signaturePublicKey,
    required this.isServerOwner,
  });

  bool authenticates(MlsDecryptedApplication application) =>
      _constantTimeEquals(application.senderCredential, credential) &&
      _constantTimeEquals(
        application.senderSignaturePublicKey,
        signaturePublicKey,
      );
}

class VerifiedMlsKeyPackage {
  final ClaimedMlsKeyPackage claimed;
  final VerifiedMlsDeviceBinding binding;

  const VerifiedMlsKeyPackage({required this.claimed, required this.binding});
}

class MlsKeyPackageService {
  static const int ciphersuite = 1;
  static const int targetInventory = 10;
  static const int maxGeneratedPerRun = 4;

  final ApiClient api;
  final MlsLocalDevice localDevice;
  final YuidIdentityService yuidIdentity;
  final String baseUrl;
  final String token;
  final Ed25519 _ed25519 = Ed25519();

  MlsKeyPackageService({
    required this.api,
    required this.localDevice,
    required this.yuidIdentity,
    required this.baseUrl,
    required this.token,
  });

  Future<int> replenish() async {
    final inventory = await api.fetchMlsKeyPackageInventory(
      baseUrl: baseUrl,
      token: token,
    );
    if (inventory.deviceId != localDevice.deviceId) {
      throw ApiException(
        'The server returned MLS inventory for another device.',
        code: 'invalid_mls_response',
      );
    }
    var needed = targetInventory - inventory.available;
    if (needed <= 0) return 0;
    if (needed > maxGeneratedPerRun) needed = maxGeneratedPerRun;

    final signaturePublicKey = await localDevice.read(
      (native) => native.signaturePublicKey,
    );
    final bindingText = await yuidIdentity.signMlsCredentialBinding(
      serverId: localDevice.serverId,
      deviceId: localDevice.deviceId,
      mlsSignaturePublicKey: signaturePublicKey,
    );
    final bindingSignature = _decodeBase64Url(bindingText);
    var registered = 0;
    while (registered < needed) {
      final remaining = needed - registered;
      final count = remaining > 2 ? 2 : remaining;
      // Persist the private KeyPackage material before exposing its public wire
      // bytes to the server. A failed upload can leave a harmless local orphan;
      // the reverse order could leave a claimed package with no private key.
      final keyPackages = await localDevice.mutate(
        (native) => List<Uint8List>.generate(
          count,
          (_) => native.generateKeyPackage(),
          growable: false,
        ),
      );
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 7));
      await api.registerMlsKeyPackages(
        baseUrl: baseUrl,
        token: token,
        expectedDeviceId: localDevice.deviceId,
        packages: keyPackages
            .map(
              (keyPackage) => MlsKeyPackageRegistration(
                ciphersuite: ciphersuite,
                signaturePublicKey: signaturePublicKey,
                identityBindingSignature: bindingSignature,
                keyPackage: keyPackage,
                expiresAt: expiresAt,
              ),
            )
            .toList(growable: false),
      );
      registered += count;
    }
    return registered;
  }

  Future<VerifiedMlsKeyPackage> claimAndVerify(String targetDeviceId) async {
    final claimed = await api.claimMlsKeyPackage(
      baseUrl: baseUrl,
      token: token,
      targetDeviceId: targetDeviceId,
    );
    return verifyClaimed(claimed);
  }

  Future<VerifiedMlsKeyPackage> verifyClaimed(
    ClaimedMlsKeyPackage claimed,
  ) async {
    if (claimed.ciphersuite != ciphersuite ||
        claimed.signaturePublicKey.length != 32 ||
        claimed.identityBindingSignature.length != 64 ||
        claimed.yuidPublicKey.length != 32) {
      throw const FormatException('Invalid MLS device binding.');
    }
    final binding = await _verifyBinding(
      deviceId: claimed.deviceId,
      yuid: claimed.yuid,
      yuidPublicKey: claimed.yuidPublicKey,
      signaturePublicKey: claimed.signaturePublicKey,
      identityBindingSignature: claimed.identityBindingSignature,
    );
    return VerifiedMlsKeyPackage(claimed: claimed, binding: binding);
  }

  Future<List<VerifiedMlsDeviceBinding>> fetchVerifiedDirectory() async {
    return _fetchVerifiedDirectory(activeOnly: true);
  }

  Future<List<VerifiedMlsDeviceBinding>>
  fetchVerifiedHistoricalDirectory() async {
    return _fetchVerifiedDirectory(activeOnly: false);
  }

  Future<List<VerifiedMlsDeviceBinding>> _fetchVerifiedDirectory({
    required bool activeOnly,
  }) async {
    final credentials = await api.fetchMlsDeviceCredentials(
      baseUrl: baseUrl,
      token: token,
    );
    if (credentials.length > 10000) {
      throw const FormatException('The MLS credential directory is oversized.');
    }
    final verified = <VerifiedMlsDeviceBinding>[];
    final unique = <String>{};
    for (final credential in credentials) {
      if (activeOnly && !credential.isActive) continue;
      final binding = await _verifyBinding(
        deviceId: credential.deviceId,
        userId: credential.userId,
        username: credential.username,
        yuid: credential.yuid,
        yuidPublicKey: credential.yuidPublicKey,
        signaturePublicKey: credential.signaturePublicKey,
        identityBindingSignature: credential.identityBindingSignature,
        isServerOwner: credential.isServerOwner,
      );
      final key =
          '${base64Url.encode(binding.credential)}|'
          '${base64Url.encode(binding.signaturePublicKey)}';
      if (!unique.add(key)) {
        throw const FormatException('Duplicate MLS credential binding.');
      }
      verified.add(binding);
    }
    return List.unmodifiable(verified);
  }

  Future<void> authenticateGroupMembers(Uint8List groupId) async {
    final directory = await fetchVerifiedDirectory();
    final members = await localDevice.read(
      (native) => native.groupMembers(groupId),
    );
    authenticateMembers(members, directory);
  }

  static void authenticateMembers(
    List<MlsGroupMember> members,
    List<VerifiedMlsDeviceBinding> directory,
  ) {
    final represented = matchAuthorizedMembers(members, directory);
    final intendedDeviceIds = directory
        .map((binding) => binding.deviceId)
        .toSet();
    final representedDeviceIds = represented
        .map((binding) => binding.deviceId)
        .toSet();
    if (representedDeviceIds.length != intendedDeviceIds.length ||
        !representedDeviceIds.containsAll(intendedDeviceIds)) {
      throw const FormatException(
        'The MLS group does not exactly match authorized devices.',
      );
    }
  }

  static List<VerifiedMlsDeviceBinding> matchAuthorizedMembers(
    List<MlsGroupMember> members,
    List<VerifiedMlsDeviceBinding> directory,
  ) {
    final represented = <VerifiedMlsDeviceBinding>[];
    final representedDeviceIds = <String>{};
    var invalid = members.isEmpty || directory.isEmpty;
    for (final member in members) {
      final matches = directory
          .where(
            (binding) =>
                _constantTimeEquals(member.credential, binding.credential) &&
                _constantTimeEquals(
                  member.signaturePublicKey,
                  binding.signaturePublicKey,
                ),
          )
          .toList(growable: false);
      if (matches.length != 1 ||
          !representedDeviceIds.add(matches.single.deviceId)) {
        invalid = true;
        break;
      }
      represented.add(matches.single);
    }
    if (invalid) {
      throw const FormatException(
        'The MLS group contains an unauthorized or duplicate device.',
      );
    }
    return List.unmodifiable(represented);
  }

  Future<MlsPreparedAdd> prepareVerifiedAdd({
    required Uint8List groupId,
    required VerifiedMlsKeyPackage keyPackage,
  }) {
    return localDevice.mutate(
      (native) => native.prepareAdd(groupId, keyPackage.claimed.keyPackage),
    );
  }

  Future<VerifiedMlsDeviceBinding> _verifyBinding({
    required String deviceId,
    String userId = '',
    String username = '',
    required String yuid,
    required Uint8List yuidPublicKey,
    required Uint8List signaturePublicKey,
    required Uint8List identityBindingSignature,
    bool isServerOwner = false,
  }) async {
    final canonicalSignatureKey = base64Url
        .encode(signaturePublicKey)
        .replaceAll('=', '');
    final message = utf8.encode(
      'yappa-mls-credential-v1|${localDevice.serverId}|$yuid|'
      '$deviceId|$canonicalSignatureKey',
    );
    final valid = await _ed25519.verify(
      message,
      signature: Signature(
        identityBindingSignature,
        publicKey: SimplePublicKey(yuidPublicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException(
        'The MLS credential is not authorized by its YUID.',
      );
    }
    return VerifiedMlsDeviceBinding(
      yuid: yuid,
      deviceId: deviceId,
      userId: userId,
      username: username,
      credential: MlsLocalDevice.credentialIdentity(
        serverId: localDevice.serverId,
        yuid: yuid,
        deviceId: deviceId,
      ),
      signaturePublicKey: Uint8List.fromList(signaturePublicKey),
      isServerOwner: isServerOwner,
    );
  }

  static Uint8List _decodeBase64Url(String value) {
    final normalized = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    return Uint8List.fromList(base64Url.decode(normalized));
  }
}

bool _constantTimeEquals(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
