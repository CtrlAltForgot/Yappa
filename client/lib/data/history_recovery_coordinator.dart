import 'package:cryptography/cryptography.dart';

import 'api_client.dart';
import 'history_recovery_crypto.dart';
import 'history_recovery_transfer_service.dart';
import 'mls_event_store.dart';
import 'mls_key_package_service.dart';

typedef HistoricalMlsCredentialDirectory =
    Future<List<VerifiedMlsDeviceBinding>> Function();

class HistoryRecoveryCoordinator {
  final HistoryRecoveryCryptor cryptor;
  final HistoryRecoveryTransferService transport;

  const HistoryRecoveryCoordinator({
    required this.cryptor,
    required this.transport,
  });

  Future<HistoryRecoveryTransfer> approveAndUpload({
    required HistoryRecoveryContext context,
    required MlsEventStore eventStore,
    required SimplePublicKey destinationRecoveryPublicKey,
    required KeyPair sourceYuidKeyPair,
  }) async {
    final records = eventStore.exportRecoveryRecords(
      firstServerSequence: context.firstServerSequence,
      lastServerSequence: context.lastServerSequence,
    );
    try {
      final sealed = await cryptor.seal(
        context: context,
        canonicalRecords: records,
        destinationRecoveryPublicKey: destinationRecoveryPublicKey,
        sourceYuidKeyPair: sourceYuidKeyPair,
      );
      return await transport.upload(context: context, sealed: sealed);
    } finally {
      records.fillRange(0, records.length, 0);
    }
  }

  Future<bool> downloadVerifyMergeAndConsume({
    required HistoryRecoveryContext expectedContext,
    required HistoryRecoveryTransfer transfer,
    required KeyPair destinationRecoveryKeyPair,
    required SimplePublicKey authorizedSourceYuidPublicKey,
    required HistoricalMlsCredentialDirectory historicalCredentials,
    required MlsEventStore eventStore,
  }) async {
    _pinTransfer(expectedContext, transfer);
    final sealed = await transport.download(transfer);
    final records = await cryptor.open(
      expectedContext: expectedContext,
      transfer: sealed,
      destinationRecoveryKeyPair: destinationRecoveryKeyPair,
      authorizedSourceYuidPublicKey: authorizedSourceYuidPublicKey,
    );
    try {
      final directory = await historicalCredentials();
      final merged = await eventStore.mergeRecoveryRecords(
        canonicalRecords: records,
        receipt: MlsHistoryRecoveryReceipt(
          transferId: transfer.id,
          manifestSha256: transfer.manifestSha256,
          sourceDeviceId: transfer.sourceDeviceId,
          destinationDeviceId: transfer.destinationDeviceId,
          firstServerSequence: transfer.firstServerSequence,
          lastServerSequence: transfer.lastServerSequence,
          eventCount: transfer.eventCount,
        ),
        authorizeSender: (event) async {
          final matches = directory.where(
            (binding) =>
                _sameBytes(binding.credential, event.senderCredential) &&
                _sameBytes(
                  binding.signaturePublicKey,
                  event.senderSignaturePublicKey,
                ),
          );
          if (matches.length != 1) {
            return const MlsRecoveredSenderAuthorization(
              authorized: false,
              senderIsOwner: false,
            );
          }
          return MlsRecoveredSenderAuthorization(
            authorized: true,
            senderIsOwner: matches.single.isServerOwner,
          );
        },
      );
      await transport.acknowledgeDurableMerge(transfer.id);
      return merged;
    } finally {
      records.fillRange(0, records.length, 0);
      for (final chunk in sealed.chunks) {
        chunk.fillRange(0, chunk.length, 0);
      }
    }
  }

  void _pinTransfer(
    HistoryRecoveryContext context,
    HistoryRecoveryTransfer transfer,
  ) {
    context.validate();
    if (transfer.id != context.transferId ||
        transfer.channelId != context.channelId ||
        transfer.sourceDeviceId != context.sourceDeviceId ||
        transfer.destinationDeviceId != context.destinationDeviceId ||
        transfer.firstServerSequence != context.firstServerSequence ||
        transfer.lastServerSequence != context.lastServerSequence ||
        transfer.eventCount != context.eventCount ||
        transfer.state != HistoryRecoveryTransferState.ready) {
      throw const FormatException(
        'Encrypted-history transfer context was substituted.',
      );
    }
  }
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
