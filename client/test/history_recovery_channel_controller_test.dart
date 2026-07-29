import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/history_recovery_channel_controller.dart';
import 'package:yappa/data/history_recovery_coordinator.dart';
import 'package:yappa/data/history_recovery_crypto.dart';
import 'package:yappa/data/history_recovery_identity.dart';
import 'package:yappa/data/history_recovery_key_service.dart';
import 'package:yappa/data/history_recovery_outbox.dart';
import 'package:yappa/data/history_recovery_transfer_service.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/secret_storage.dart';
import 'package:yappa/data/yuid_identity_service.dart';
import 'package:yappa/features/chat/history_recovery_notice.dart';

class _MemorySecrets implements SecretStorage {
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

class _EmptyTransport extends HistoryRecoveryTransferService {
  String? canceledTransferId;
  ApiException? cancelError;

  _EmptyTransport()
    : super(
        api: ApiClient(),
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
      );

  @override
  Future<List<HistoryRecoveryTransfer>> available({
    required String channelId,
    required String destinationDeviceId,
  }) async => const [];

  @override
  Future<bool> cancel(String transferId) async {
    canceledTransferId = transferId;
    final error = cancelError;
    if (error != null) throw error;
    return true;
  }
}

class _CapturingCoordinator extends HistoryRecoveryCoordinator {
  HistoryRecoveryContext? approvedContext;
  HistoryRecoveryContext? uploadedContext;
  bool failUploads;

  _CapturingCoordinator(
    HistoryRecoveryTransferService transport, {
    this.failUploads = false,
  }) : super(cryptor: HistoryRecoveryCryptor(), transport: transport);

  @override
  Future<SealedHistoryRecoveryTransfer> prepareUpload({
    required HistoryRecoveryContext context,
    required MlsEventStore eventStore,
    required SimplePublicKey destinationRecoveryPublicKey,
    required KeyPair sourceYuidKeyPair,
  }) async {
    approvedContext = context;
    return SealedHistoryRecoveryTransfer(
      manifest: Uint8List.fromList([1]),
      manifestSha256: '0' * 64,
      yuidSignature: 'a' * 86,
      chunks: [
        Uint8List.fromList([1]),
      ],
    );
  }

  @override
  Future<HistoryRecoveryTransfer> uploadPrepared({
    required HistoryRecoveryContext context,
    required SealedHistoryRecoveryTransfer sealed,
  }) async {
    uploadedContext = context;
    if (failUploads) throw ApiException('Simulated lost upload response.');
    return HistoryRecoveryTransfer(
      id: context.transferId,
      channelId: context.channelId,
      sourceDeviceId: context.sourceDeviceId,
      destinationDeviceId: context.destinationDeviceId,
      firstServerSequence: context.firstServerSequence,
      lastServerSequence: context.lastServerSequence,
      eventCount: context.eventCount,
      chunkCount: 1,
      totalBytes: 1,
      manifest: Uint8List.fromList([1]),
      manifestSha256: '0' * 64,
      yuidSignature: 'a' * 86,
      state: HistoryRecoveryTransferState.ready,
      uploadedChunks: 1,
      uploadedBytes: 1,
      createdAt: DateTime.utc(2026),
      readyAt: DateTime.utc(2026),
      consumedAt: null,
      canceledAt: null,
      expiresAt: DateTime.utc(2026, 8),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'discovers destinations and shares the exact sparse event range',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'yappa-history-channel-controller-',
      );
      addTearDown(() => root.delete(recursive: true));
      final secrets = _MemorySecrets();
      final localDeviceId = 'device_${'l' * 24}';
      final destinationDeviceId = 'device_${'d' * 24}';
      final store = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: localDeviceId,
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      for (final sequence in [1, 3]) {
        await store.apply(
          MlsApplicationEvent(
            serverSequence: sequence,
            epoch: 1,
            eventId: String.fromCharCode(96 + sequence) * 22,
            channelId: '1',
            kind: EncryptedApplicationEventKind.message,
            targetEventId: null,
            createdAt: DateTime.utc(2026, 7, 28, 12, sequence),
            body: {'content': 'event $sequence'},
            senderCredential: Uint8List.fromList([sequence]),
            senderSignaturePublicKey: Uint8List.fromList(
              List<int>.filled(32, sequence),
            ),
          ),
          senderIsOwner: false,
        );
      }
      final recoveryIdentity = HistoryRecoveryIdentityService(
        secretStorage: secrets,
      );
      final localRecovery = await recoveryIdentity.getOrCreate(
        serverId: 'server-id',
        deviceId: localDeviceId,
      );
      final localPublic = SimplePublicKey(
        _decode(localRecovery.publicKeyBase64Url),
        type: KeyPairType.x25519,
      );
      final destinationPublic = await X25519().newKeyPair().then(
        (keyPair) => keyPair.extractPublicKey(),
      );
      final yuid = YuidIdentityService(secretStorage: secrets);
      final account = await yuid.getOrCreateIdentity();
      final transport = _EmptyTransport();
      final coordinator = _CapturingCoordinator(transport, failUploads: true);
      final firstOutbox = await HistoryRecoveryOutbox.open(
        serverId: 'server-id',
        deviceId: localDeviceId,
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      Future<List<VerifiedHistoryRecoveryDeviceKey>> keys() async => [
        VerifiedHistoryRecoveryDeviceKey(
          accountYuid: account.yuid,
          deviceId: localDeviceId,
          publicKey: localPublic,
        ),
        VerifiedHistoryRecoveryDeviceKey(
          accountYuid: account.yuid,
          deviceId: destinationDeviceId,
          publicKey: destinationPublic,
        ),
      ];
      final controller = HistoryRecoveryChannelController(
        serverId: 'server-id',
        channelId: '1',
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        localDeviceId: localDeviceId,
        api: ApiClient(),
        eventStore: store,
        recoveryIdentity: recoveryIdentity,
        yuidIdentity: yuid,
        outbox: firstOutbox,
        historicalCredentials: () async => const [],
        verifiedRecoveryKeys: keys,
        transport: transport,
        coordinator: coordinator,
      );

      final discovered = await controller.refresh();
      expect(discovered.phase, HistoryRecoveryUiPhase.approvalRequired);
      expect(discovered.destinations.single.deviceId, destinationDeviceId);
      await expectLater(
        controller.perform(destinationDeviceId),
        throwsA(isA<ApiException>()),
      );
      expect(controller.state.phase, HistoryRecoveryUiPhase.failed);
      expect(coordinator.approvedContext?.firstServerSequence, 1);
      expect(coordinator.approvedContext?.lastServerSequence, 3);
      expect(coordinator.approvedContext?.eventCount, 2);
      expect(
        coordinator.approvedContext?.destinationDeviceId,
        destinationDeviceId,
      );
      final pendingTransferId = coordinator.approvedContext!.transferId;
      expect((await firstOutbox.read())?.context.transferId, pendingTransferId);
      await controller.close();

      final resumedOutbox = await HistoryRecoveryOutbox.open(
        serverId: 'server-id',
        deviceId: localDeviceId,
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      final resumedCoordinator = _CapturingCoordinator(transport);
      final resumed = HistoryRecoveryChannelController(
        serverId: 'server-id',
        channelId: '1',
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        localDeviceId: localDeviceId,
        api: ApiClient(),
        eventStore: store,
        recoveryIdentity: recoveryIdentity,
        yuidIdentity: yuid,
        outbox: resumedOutbox,
        historicalCredentials: () async => const [],
        verifiedRecoveryKeys: keys,
        transport: transport,
        coordinator: resumedCoordinator,
      );
      expect((await resumed.refresh()).phase, HistoryRecoveryUiPhase.shared);
      expect(resumedCoordinator.uploadedContext?.transferId, pendingTransferId);
      expect(await resumedOutbox.read(), isNull);

      await store.apply(
        MlsApplicationEvent(
          serverSequence: 5,
          epoch: 1,
          eventId: 'e' * 22,
          channelId: '1',
          kind: EncryptedApplicationEventKind.message,
          targetEventId: null,
          createdAt: DateTime.utc(2026, 7, 28, 12, 5),
          body: const {'content': 'event 5'},
          senderCredential: Uint8List.fromList([5]),
          senderSignaturePublicKey: Uint8List.fromList(List<int>.filled(32, 5)),
        ),
        senderIsOwner: false,
      );
      resumedCoordinator.failUploads = true;
      expect(
        (await resumed.refresh()).phase,
        HistoryRecoveryUiPhase.approvalRequired,
      );
      await expectLater(
        resumed.perform(destinationDeviceId),
        throwsA(isA<ApiException>()),
      );
      final stoppedTransferId =
          (await resumedOutbox.read())!.context.transferId;
      expect(resumed.state.canCancel, isTrue);
      await resumed.cancelPendingUpload();
      expect(transport.canceledTransferId, stoppedTransferId);
      expect(await resumedOutbox.read(), isNull);

      await resumed.perform(destinationDeviceId).catchError((_) => false);
      final retainedTransferId =
          (await resumedOutbox.read())!.context.transferId;
      transport.cancelError = ApiException(
        'Uncertain cancellation.',
        statusCode: 503,
      );
      await expectLater(
        resumed.cancelPendingUpload(),
        throwsA(isA<ApiException>()),
      );
      expect(
        (await resumedOutbox.read())?.context.transferId,
        retainedTransferId,
      );
      await resumed.close();
      await store.close();
    },
  );
}

Uint8List _decode(String value) => Uint8List.fromList(
  base64Url.decode(
    value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
  ),
);
