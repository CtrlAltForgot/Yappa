import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'api_client.dart';
import 'mls_delivery_models.dart';
import 'mls_event_store.dart';
import 'mls_local_state.dart';
import 'mls_native.dart';

class MlsSendCoordinator {
  final ApiClient api;
  final MlsLocalDevice localDevice;
  final MlsEventStore eventStore;
  final String baseUrl;
  final String token;
  final String serverId;
  final String channelId;
  final bool senderIsOwner;
  final Random _random;

  MlsSendCoordinator({
    required this.api,
    required this.localDevice,
    required this.eventStore,
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.channelId,
    required this.senderIsOwner,
    Random? random,
  }) : _random = random ?? Random.secure();

  Uint8List get groupId =>
      Uint8List.fromList(utf8.encode('yappa-text-v1|$serverId|$channelId'));

  Future<MlsDeliveryMessage> send({
    required EncryptedApplicationEventKind kind,
    required Map<String, dynamic> body,
    String? targetEventId,
    DateTime? createdAt,
  }) async {
    final outgoing = await stage(
      kind: kind,
      body: body,
      targetEventId: targetEventId,
      createdAt: createdAt,
    );
    return _submit(outgoing.operationId);
  }

  Future<MlsOutgoingApplication> stage({
    required EncryptedApplicationEventKind kind,
    required Map<String, dynamic> body,
    String? targetEventId,
    DateTime? createdAt,
    String? eventId,
    String? operationId,
  }) async {
    if (await localDevice.read(
      (native) => native.pendingOutgoingApplications().isNotEmpty,
    )) {
      throw const FormatException(
        'Resume the pending encrypted message before sending another.',
      );
    }
    final selectedEventId = eventId ?? _randomId();
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocol': 'yappa-message-v1',
          'eventId': selectedEventId,
          'channelId': channelId,
          'kind': kind.name,
          'targetEventId': targetEventId,
          'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
          'body': body,
        }),
      ),
    );
    MlsApplicationEvent.routingFromPlaintext(
      plaintext: plaintext,
      channelId: channelId,
    );
    final selectedOperationId = operationId ?? 'mlsop_${_randomId()}';
    return localDevice.mutate(
      (native) => native.stageOutgoingApplication(
        groupId,
        selectedOperationId,
        plaintext,
      ),
    );
  }

  Future<MlsDeliveryMessage> submitPendingOperation(String operationId) =>
      _submit(operationId);

  Future<List<MlsDeliveryMessage>> resumePending() async {
    final pending = await localDevice.read(
      (native) => native.pendingOutgoingApplications(),
    );
    final delivered = <MlsDeliveryMessage>[];
    for (final item in pending) {
      delivered.add(await _submit(item.operationId));
    }
    return delivered;
  }

  Future<MlsDeliveryMessage> _submit(String operationId) async {
    final outgoing = await localDevice.read(
      (native) => native.pendingOutgoingApplications().singleWhere(
        (item) => item.operationId == operationId,
      ),
    );
    if (!_sameBytes(outgoing.groupId, groupId)) {
      throw const FormatException(
        'The pending encrypted message belongs to another channel.',
      );
    }
    final routing = MlsApplicationEvent.routingFromPlaintext(
      plaintext: outgoing.plaintext,
      channelId: channelId,
    );
    late final MlsDeliveryMessage delivery;
    try {
      delivery = await api.submitMlsDeliveryMessage(
        baseUrl: baseUrl,
        token: token,
        channelId: channelId,
        clientOperationId: operationId,
        messageClass: MlsDeliveryMessageClass.application,
        acceptedEpoch: outgoing.epoch,
        wireMessage: outgoing.wire,
        event: routing,
      );
    } on ApiException catch (error) {
      if (error.code == 'mls_epoch_conflict') {
        await localDevice.mutate(
          (native) => native.clearOutgoingApplication(operationId),
        );
      }
      rethrow;
    }
    final signatureKey = await localDevice.read(
      (native) => native.signaturePublicKey,
    );
    final materialized = MlsApplicationEvent.parse(
      delivery: delivery,
      application: MlsDecryptedApplication(
        epoch: outgoing.epoch,
        senderCredential: localDevice.identity,
        senderSignaturePublicKey: signatureKey,
        plaintext: outgoing.plaintext,
      ),
    );
    await eventStore.apply(materialized, senderIsOwner: senderIsOwner);
    await localDevice.mutate(
      (native) => native.clearOutgoingApplication(operationId),
    );
    return delivery;
  }

  String _randomId() {
    final bytes = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
      growable: false,
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
