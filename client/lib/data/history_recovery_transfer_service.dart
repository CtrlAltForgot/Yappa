import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';
import 'history_recovery_crypto.dart';

class HistoryRecoveryTransferService {
  final ApiClient api;
  final String baseUrl;
  final String token;

  const HistoryRecoveryTransferService({
    required this.api,
    required this.baseUrl,
    required this.token,
  });

  Future<HistoryRecoveryTransfer> upload({
    required HistoryRecoveryContext context,
    required SealedHistoryRecoveryTransfer sealed,
  }) async {
    context.validate();
    if (sealed.chunks.isEmpty ||
        sealed.chunks.length > HistoryRecoveryCryptor.maxChunkCount) {
      throw const FormatException('Invalid encrypted-history transfer.');
    }
    final totalBytes = sealed.chunks.fold<int>(
      0,
      (total, chunk) => total + chunk.length,
    );
    if (totalBytes < sealed.chunks.length ||
        totalBytes > HistoryRecoveryCryptor.maxCiphertextBytes ||
        sealed.chunks.any(
          (chunk) =>
              chunk.isEmpty ||
              chunk.length > HistoryRecoveryCryptor.maxCiphertextChunkBytes,
        )) {
      throw const FormatException('Invalid encrypted-history transfer.');
    }
    final created = await api.createHistoryRecoveryTransfer(
      baseUrl: baseUrl,
      token: token,
      channelId: context.channelId,
      transferId: context.transferId,
      sourceDeviceId: context.sourceDeviceId,
      destinationDeviceId: context.destinationDeviceId,
      firstServerSequence: context.firstServerSequence,
      lastServerSequence: context.lastServerSequence,
      eventCount: context.eventCount,
      chunkCount: sealed.chunks.length,
      totalBytes: totalBytes,
      manifest: sealed.manifest,
      manifestSha256: sealed.manifestSha256,
      yuidSignature: sealed.yuidSignature,
    );
    if (created.transfer.state == HistoryRecoveryTransferState.ready) {
      return created.transfer;
    }
    if (created.transfer.state != HistoryRecoveryTransferState.uploading) {
      throw ApiException(
        'That encrypted-history transfer can no longer be uploaded.',
        code: 'history_recovery_transfer_not_uploading',
      );
    }
    final chunkMetadata = _chunkMetadata(
      manifest: sealed.manifest,
      expectedChunkCount: sealed.chunks.length,
      expectedTotalBytes: totalBytes,
    );
    for (var index = 0; index < sealed.chunks.length; index++) {
      await api.uploadHistoryRecoveryChunk(
        baseUrl: baseUrl,
        token: token,
        transferId: context.transferId,
        chunkIndex: index,
        ciphertext: sealed.chunks[index],
        ciphertextSha256: chunkMetadata[index].sha256,
      );
    }
    final finalized = await api.finalizeHistoryRecoveryTransfer(
      baseUrl: baseUrl,
      token: token,
      transferId: context.transferId,
    );
    return finalized.transfer;
  }

  Future<List<HistoryRecoveryTransfer>> available({
    required String channelId,
    required String destinationDeviceId,
  }) {
    return api.fetchHistoryRecoveryTransfers(
      baseUrl: baseUrl,
      token: token,
      channelId: channelId,
      destinationDeviceId: destinationDeviceId,
    );
  }

  Future<SealedHistoryRecoveryTransfer> download(
    HistoryRecoveryTransfer transfer,
  ) async {
    if (transfer.state != HistoryRecoveryTransferState.ready ||
        transfer.manifest == null) {
      throw const FormatException(
        'Encrypted-history transfer is not ready to download.',
      );
    }
    final metadata = _chunkMetadata(
      manifest: transfer.manifest!,
      expectedChunkCount: transfer.chunkCount,
      expectedTotalBytes: transfer.totalBytes,
    );
    final chunks = <Uint8List>[];
    for (final item in metadata) {
      final chunk = await api.downloadHistoryRecoveryChunk(
        baseUrl: baseUrl,
        token: token,
        transferId: transfer.id,
        chunkIndex: item.index,
        expectedSha256: item.sha256,
        expectedSizeBytes: item.sizeBytes,
      );
      chunks.add(chunk.ciphertext);
    }
    return SealedHistoryRecoveryTransfer(
      manifest: transfer.manifest!,
      manifestSha256: transfer.manifestSha256,
      yuidSignature: transfer.yuidSignature,
      chunks: List.unmodifiable(chunks),
    );
  }

  Future<HistoryRecoveryTransfer> acknowledgeDurableMerge(
    String transferId,
  ) async {
    final result = await api.consumeHistoryRecoveryTransfer(
      baseUrl: baseUrl,
      token: token,
      transferId: transferId,
    );
    return result.transfer;
  }

  Future<bool> cancel(String transferId) {
    return api.cancelHistoryRecoveryTransfer(
      baseUrl: baseUrl,
      token: token,
      transferId: transferId,
    );
  }

  List<_ChunkMetadata> _chunkMetadata({
    required Uint8List manifest,
    required int expectedChunkCount,
    required int expectedTotalBytes,
  }) {
    try {
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(manifest)) as Map,
      );
      final raw = decoded['chunks'];
      if (raw is! List || raw.length != expectedChunkCount) {
        throw const FormatException();
      }
      final result = <_ChunkMetadata>[];
      var total = 0;
      for (var index = 0; index < raw.length; index++) {
        final item = Map<String, dynamic>.from(raw[index] as Map);
        final size = item['sizeBytes'];
        final digest = item['ciphertextSha256']?.toString() ?? '';
        if (item.length != 3 ||
            item['index'] != index ||
            size is! int ||
            size < 1 ||
            size > HistoryRecoveryCryptor.maxCiphertextChunkBytes ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
          throw const FormatException();
        }
        total += size;
        result.add(
          _ChunkMetadata(index: index, sizeBytes: size, sha256: digest),
        );
      }
      if (total != expectedTotalBytes) throw const FormatException();
      return result;
    } catch (_) {
      throw const FormatException(
        'Invalid encrypted-history manifest chunk metadata.',
      );
    }
  }
}

class _ChunkMetadata {
  final int index;
  final int sizeBytes;
  final String sha256;

  const _ChunkMetadata({
    required this.index,
    required this.sizeBytes,
    required this.sha256,
  });
}
