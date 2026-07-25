import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'api_client.dart';
import 'mls_delivery_models.dart';
import 'mls_local_state.dart';
import 'mls_outbox.dart';

typedef MlsDeliverySubmitter =
    Future<MlsDeliveryMessage> Function({
      required String channelId,
      required String clientOperationId,
      required MlsDeliveryMessageClass messageClass,
      required int acceptedEpoch,
      required Uint8List wireMessage,
      int? parentEpoch,
      String? recipientDeviceId,
    });

class MlsAddCoordinator {
  final MlsLocalDevice localDevice;
  final MlsOutbox outbox;
  final MlsDeliverySubmitter submit;
  final Random _random;

  MlsAddCoordinator({
    required this.localDevice,
    required this.outbox,
    required this.submit,
    Random? random,
  }) : _random = random ?? Random.secure();

  Future<void> add({
    required String channelId,
    required String recipientDeviceId,
    required Uint8List groupId,
    required Uint8List verifiedKeyPackage,
  }) async {
    if (await outbox.read() != null) {
      throw const MlsOutboxException(
        'Resume the pending MLS membership operation before starting another.',
      );
    }
    final prepared = await localDevice.mutate(
      (native) => native.prepareAdd(groupId, verifiedKeyPackage),
    );
    final entry = MlsAddOutboxEntry(
      channelId: channelId,
      recipientDeviceId: recipientDeviceId,
      parentEpoch: prepared.parentEpoch,
      acceptedEpoch: prepared.acceptedEpoch,
      commitOperationId: _operationId(),
      welcomeOperationId: _operationId(),
      commit: prepared.commit,
      welcome: prepared.welcome,
      stage: MlsAddOutboxStage.commitPending,
    );
    await outbox.write(entry);
    await resume(groupId: groupId);
  }

  Future<bool> resume({required Uint8List groupId}) async {
    var entry = await outbox.read();
    if (entry == null) return false;

    if (entry.stage == MlsAddOutboxStage.commitPending) {
      try {
        await submit(
          channelId: entry.channelId,
          clientOperationId: entry.commitOperationId,
          messageClass: MlsDeliveryMessageClass.commit,
          acceptedEpoch: entry.acceptedEpoch,
          parentEpoch: entry.parentEpoch,
          wireMessage: entry.commit,
        );
      } on ApiException catch (error) {
        if (error.code == 'mls_epoch_conflict') {
          await _rejectIfPending(groupId, entry.parentEpoch);
          await outbox.clear();
        }
        rethrow;
      }
      entry = entry.commitAccepted();
      await outbox.write(entry);
    }

    if (entry.stage == MlsAddOutboxStage.commitAccepted) {
      final localEpoch = await localDevice.read(
        (native) => native.epoch(groupId),
      );
      if (localEpoch == entry.parentEpoch) {
        final accepted = await localDevice.mutate(
          (native) => native.acceptPendingCommit(groupId),
        );
        if (accepted != entry.acceptedEpoch) {
          throw const MlsOutboxException(
            'The local MLS commit advanced to an unexpected epoch.',
          );
        }
      } else if (localEpoch != entry.acceptedEpoch) {
        throw const MlsOutboxException(
          'The local MLS state cannot resume the accepted commit.',
        );
      }
      entry = entry.welcomePending();
      await outbox.write(entry);
    }

    await submit(
      channelId: entry.channelId,
      clientOperationId: entry.welcomeOperationId,
      messageClass: MlsDeliveryMessageClass.welcome,
      acceptedEpoch: entry.acceptedEpoch,
      recipientDeviceId: entry.recipientDeviceId,
      wireMessage: entry.welcome,
    );
    await outbox.clear();
    return true;
  }

  Future<void> _rejectIfPending(Uint8List groupId, int parentEpoch) async {
    final localEpoch = await localDevice.read(
      (native) => native.epoch(groupId),
    );
    if (localEpoch == parentEpoch) {
      await localDevice.mutate((native) => native.rejectPendingCommit(groupId));
    }
  }

  String _operationId() {
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256), growable: false),
    );
    return 'mlsop_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}

MlsDeliverySubmitter apiMlsDeliverySubmitter({
  required ApiClient api,
  required String baseUrl,
  required String token,
}) {
  return ({
    required channelId,
    required clientOperationId,
    required messageClass,
    required acceptedEpoch,
    required wireMessage,
    parentEpoch,
    recipientDeviceId,
  }) => api.submitMlsDeliveryMessage(
    baseUrl: baseUrl,
    token: token,
    channelId: channelId,
    clientOperationId: clientOperationId,
    messageClass: messageClass,
    acceptedEpoch: acceptedEpoch,
    parentEpoch: parentEpoch,
    recipientDeviceId: recipientDeviceId,
    wireMessage: wireMessage,
  );
}
