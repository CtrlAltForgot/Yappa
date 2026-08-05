import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/history_recovery_coordinator.dart';
import 'package:yappa/data/history_recovery_crypto.dart';
import 'package:yappa/data/history_recovery_transfer_service.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/mls_key_package_service.dart';
import 'package:yappa/data/secret_storage.dart';

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

class _MemoryTransport extends HistoryRecoveryTransferService {
  SealedHistoryRecoveryTransfer? sealed;
  HistoryRecoveryTransfer? transfer;
  var consumed = false;

  _MemoryTransport()
    : super(
        api: ApiClient(),
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
      );

  @override
  Future<HistoryRecoveryTransfer> upload({
    required HistoryRecoveryContext context,
    required SealedHistoryRecoveryTransfer sealed,
  }) async {
    this.sealed = sealed;
    final total = sealed.chunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.length,
    );
    transfer = HistoryRecoveryTransfer(
      id: context.transferId,
      channelId: context.channelId,
      sourceDeviceId: context.sourceDeviceId,
      destinationDeviceId: context.destinationDeviceId,
      firstServerSequence: context.firstServerSequence,
      lastServerSequence: context.lastServerSequence,
      eventCount: context.eventCount,
      chunkCount: sealed.chunks.length,
      totalBytes: total,
      manifest: sealed.manifest,
      manifestSha256: sealed.manifestSha256,
      yuidSignature: sealed.yuidSignature,
      state: HistoryRecoveryTransferState.ready,
      uploadedChunks: sealed.chunks.length,
      uploadedBytes: total,
      createdAt: DateTime.utc(2026, 7, 28, 12),
      readyAt: DateTime.utc(2026, 7, 28, 12, 1),
      consumedAt: null,
      canceledAt: null,
      expiresAt: DateTime.utc(2026, 8, 27, 12),
    );
    return transfer!;
  }

  @override
  Future<SealedHistoryRecoveryTransfer> download(
    HistoryRecoveryTransfer transfer,
  ) async => sealed!;

  @override
  Future<HistoryRecoveryTransfer> acknowledgeDurableMerge(
    String transferId,
  ) async {
    consumed = true;
    return transfer!;
  }
}

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recovers, reauthorizes, durably merges, then consumes', () async {
    final root = await Directory.systemTemp.createTemp(
      'yappa-history-coordinator-',
    );
    addTearDown(() => root.delete(recursive: true));
    final secrets = _MemorySecrets();
    final sourceDevice = 'device_${'s' * 24}';
    final destinationDevice = 'device_${'d' * 24}';
    final sourceStore = await MlsEventStore.open(
      serverId: 'server-id',
      deviceId: sourceDevice,
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final credential = Uint8List.fromList([1, 2, 3]);
    final senderKey = Uint8List.fromList(List<int>.filled(32, 9));
    await sourceStore.apply(
      MlsApplicationEvent(
        serverSequence: 1,
        epoch: 2,
        eventId: 'm' * 22,
        channelId: '1',
        kind: EncryptedApplicationEventKind.message,
        targetEventId: null,
        createdAt: DateTime.utc(2026, 7, 28),
        body: const {'content': 'end-to-end recovered'},
        senderCredential: credential,
        senderSignaturePublicKey: senderKey,
      ),
      senderIsOwner: false,
    );

    final x25519 = X25519();
    final sourceRecovery = await x25519.newKeyPair();
    final destinationRecovery = await x25519.newKeyPair();
    final sourceRecoveryPublic = await sourceRecovery.extractPublicKey();
    final destinationRecoveryPublic = await destinationRecovery
        .extractPublicKey();
    final yuid = await Ed25519().newKeyPair();
    final yuidPublic = await yuid.extractPublicKey();
    final context = HistoryRecoveryContext(
      transferId: 'recovery_abcdefghijklmnopqrstuv',
      serverId: 'server-id',
      channelId: '1',
      accountYuid: 'abcdefghijklmnopqrst',
      sourceDeviceId: sourceDevice,
      destinationDeviceId: destinationDevice,
      sourceRecoveryPublicKey: _encode(sourceRecoveryPublic.bytes),
      destinationRecoveryPublicKey: _encode(destinationRecoveryPublic.bytes),
      firstServerSequence: 1,
      lastServerSequence: 1,
      eventCount: 1,
    );
    final transport = _MemoryTransport();
    final coordinator = HistoryRecoveryCoordinator(
      cryptor: HistoryRecoveryCryptor(),
      transport: transport,
    );
    final transfer = await coordinator.approveAndUpload(
      context: context,
      eventStore: sourceStore,
      destinationRecoveryPublicKey: destinationRecoveryPublic,
      sourceYuidKeyPair: yuid,
    );
    expect(transport.consumed, isFalse);

    final destinationStore = await MlsEventStore.open(
      serverId: 'server-id',
      deviceId: destinationDevice,
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final merged = await coordinator.downloadVerifyMergeAndConsume(
      expectedContext: context,
      transfer: transfer,
      destinationRecoveryKeyPair: destinationRecovery,
      authorizedSourceYuidPublicKey: yuidPublic,
      historicalCredentials: () async => [
        VerifiedMlsDeviceBinding(
          yuid: 'sender-yuid',
          deviceId: 'device_${'x' * 24}',
          credential: credential,
          signaturePublicKey: senderKey,
          isServerOwner: false,
        ),
      ],
      eventStore: destinationStore,
    );
    expect(merged, isTrue);
    expect(
      destinationStore.events.single.body['content'],
      'end-to-end recovered',
    );
    expect(destinationStore.recoveryReceipts, hasLength(1));
    expect(transport.consumed, isTrue);
    await sourceStore.close();
    await destinationStore.close();
  });
}
