import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/history_recovery_crypto.dart';
import 'package:yappa/data/history_recovery_transfer_service.dart';

const _transferId = 'recovery_abcdefghijklmnopqrstuv';
const _sourceDeviceId = 'device_abcdefghijklmnopqrstuvwx';
const _destinationDeviceId = 'device_zyxwvutsrqponmlkjihgfedc';
const _signature =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    'abcdefghijklmnopqrstuvwx';

class _TransferApi extends ApiClient {
  late HistoryRecoveryTransfer transfer;
  final List<Uint8List> chunks;
  final List<int> uploaded = [];
  var consumed = false;

  _TransferApi(this.chunks);

  @override
  Future<HistoryRecoveryTransferResult> createHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String channelId,
    required String transferId,
    required String sourceDeviceId,
    required String destinationDeviceId,
    required int firstServerSequence,
    required int lastServerSequence,
    required int chunkCount,
    required int totalBytes,
    required Uint8List manifest,
    required String manifestSha256,
    required String yuidSignature,
  }) async => HistoryRecoveryTransferResult(changed: false, transfer: transfer);

  @override
  Future<bool> uploadHistoryRecoveryChunk({
    required String baseUrl,
    required String token,
    required String transferId,
    required int chunkIndex,
    required Uint8List ciphertext,
    required String ciphertextSha256,
  }) async {
    expect(ciphertext, chunks[chunkIndex]);
    expect(sha256.convert(ciphertext).toString(), ciphertextSha256);
    uploaded.add(chunkIndex);
    return false;
  }

  @override
  Future<HistoryRecoveryTransferResult> finalizeHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String transferId,
  }) async {
    transfer = _copy(state: HistoryRecoveryTransferState.ready);
    return HistoryRecoveryTransferResult(changed: true, transfer: transfer);
  }

  @override
  Future<List<HistoryRecoveryTransfer>> fetchHistoryRecoveryTransfers({
    required String baseUrl,
    required String token,
    required String channelId,
    required String destinationDeviceId,
  }) async => [transfer];

  @override
  Future<HistoryRecoveryChunk> downloadHistoryRecoveryChunk({
    required String baseUrl,
    required String token,
    required String transferId,
    required int chunkIndex,
    required String expectedSha256,
    required int expectedSizeBytes,
  }) async => HistoryRecoveryChunk(
    transferId: transferId,
    chunkIndex: chunkIndex,
    ciphertext: chunks[chunkIndex],
    ciphertextSha256: expectedSha256,
  );

  @override
  Future<HistoryRecoveryTransferResult> consumeHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String transferId,
  }) async {
    consumed = true;
    transfer = _copy(state: HistoryRecoveryTransferState.consumed);
    return HistoryRecoveryTransferResult(changed: true, transfer: transfer);
  }

  HistoryRecoveryTransfer _copy({
    required HistoryRecoveryTransferState state,
  }) => HistoryRecoveryTransfer(
    id: transfer.id,
    channelId: transfer.channelId,
    sourceDeviceId: transfer.sourceDeviceId,
    destinationDeviceId: transfer.destinationDeviceId,
    firstServerSequence: transfer.firstServerSequence,
    lastServerSequence: transfer.lastServerSequence,
    eventCount: transfer.eventCount,
    chunkCount: transfer.chunkCount,
    totalBytes: transfer.totalBytes,
    manifest: transfer.manifest,
    manifestSha256: transfer.manifestSha256,
    yuidSignature: transfer.yuidSignature,
    state: state,
    uploadedChunks: state == HistoryRecoveryTransferState.uploading ? 0 : 2,
    uploadedBytes: state == HistoryRecoveryTransferState.uploading ? 0 : 6,
    createdAt: transfer.createdAt,
    readyAt: state == HistoryRecoveryTransferState.uploading
        ? null
        : DateTime.utc(2026, 7, 28, 12, 1),
    consumedAt: state == HistoryRecoveryTransferState.consumed
        ? DateTime.utc(2026, 7, 28, 12, 2)
        : null,
    canceledAt: null,
    expiresAt: transfer.expiresAt,
  );
}

void main() {
  test(
    'resumes exact chunks and consumes only after explicit merge ack',
    () async {
      final chunks = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ];
      final manifest = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'chunks': [
              {
                'ciphertextSha256': sha256.convert(chunks[0]).toString(),
                'index': 0,
                'sizeBytes': 3,
              },
              {
                'ciphertextSha256': sha256.convert(chunks[1]).toString(),
                'index': 1,
                'sizeBytes': 3,
              },
            ],
            'header': const {},
            'headerSha256': '0' * 64,
          }),
        ),
      );
      final api = _TransferApi(chunks);
      api.transfer = HistoryRecoveryTransfer(
        id: _transferId,
        channelId: '7',
        sourceDeviceId: _sourceDeviceId,
        destinationDeviceId: _destinationDeviceId,
        firstServerSequence: 10,
        lastServerSequence: 11,
        eventCount: 2,
        chunkCount: 2,
        totalBytes: 6,
        manifest: manifest,
        manifestSha256: sha256.convert(manifest).toString(),
        yuidSignature: _signature,
        state: HistoryRecoveryTransferState.uploading,
        uploadedChunks: 1,
        uploadedBytes: 3,
        createdAt: DateTime.utc(2026, 7, 28, 12),
        readyAt: null,
        consumedAt: null,
        canceledAt: null,
        expiresAt: DateTime.utc(2026, 8, 4, 12),
      );
      const context = HistoryRecoveryContext(
        transferId: _transferId,
        serverId: 'server-test',
        channelId: '7',
        accountYuid: 'abcdefghijklmnopqrst',
        sourceDeviceId: _sourceDeviceId,
        destinationDeviceId: _destinationDeviceId,
        sourceRecoveryPublicKey: 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
        destinationRecoveryPublicKey:
            'zyxwvutsrqponmlkjihgfedcbaABCDEFGHIJKLMNOPQ',
        firstServerSequence: 10,
        lastServerSequence: 11,
        eventCount: 2,
      );
      final sealed = SealedHistoryRecoveryTransfer(
        manifest: manifest,
        manifestSha256: sha256.convert(manifest).toString(),
        yuidSignature: _signature,
        chunks: chunks,
      );
      final service = HistoryRecoveryTransferService(
        api: api,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
      );

      final ready = await service.upload(context: context, sealed: sealed);
      expect(ready.state, HistoryRecoveryTransferState.ready);
      expect(api.uploaded, [0, 1]);
      final downloaded = await service.download(ready);
      expect(downloaded.chunks, chunks);
      expect(api.consumed, isFalse);
      final consumed = await service.acknowledgeDurableMerge(_transferId);
      expect(consumed.state, HistoryRecoveryTransferState.consumed);
      expect(api.consumed, isTrue);
    },
  );
}
