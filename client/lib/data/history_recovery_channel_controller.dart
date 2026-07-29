import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../features/chat/history_recovery_notice.dart';
import 'api_client.dart';
import 'history_recovery_coordinator.dart';
import 'history_recovery_crypto.dart';
import 'history_recovery_identity.dart';
import 'history_recovery_key_service.dart';
import 'history_recovery_outbox.dart';
import 'history_recovery_transfer_service.dart';
import 'mls_event_store.dart';
import 'yuid_identity_service.dart';

class HistoryRecoveryChannelController {
  final String serverId;
  final String channelId;
  final String baseUrl;
  final String token;
  final String localDeviceId;
  final ApiClient api;
  final MlsEventStore eventStore;
  final HistoryRecoveryIdentityService recoveryIdentity;
  final YuidIdentityService yuidIdentity;
  final HistoryRecoveryOutbox outbox;
  final HistoricalMlsCredentialDirectory historicalCredentials;
  final Future<List<VerifiedHistoryRecoveryDeviceKey>> Function()
  verifiedRecoveryKeys;
  late final HistoryRecoveryTransferService _transport;
  late final HistoryRecoveryCoordinator _coordinator;

  HistoryRecoveryUiState state = const HistoryRecoveryUiState(
    phase: HistoryRecoveryUiPhase.beginsOnThisDevice,
  );
  Map<String, VerifiedHistoryRecoveryDeviceKey> _keys = const {};
  HistoryRecoveryTransfer? _pendingTransfer;
  String? _retryDestinationId;
  bool _retryReceive = false;
  String? _sharedDestinationId;
  int? _sharedLastSequence;

  HistoryRecoveryChannelController({
    required this.serverId,
    required this.channelId,
    required this.baseUrl,
    required this.token,
    required this.localDeviceId,
    required this.api,
    required this.eventStore,
    required this.recoveryIdentity,
    required this.yuidIdentity,
    required this.outbox,
    required this.historicalCredentials,
    required this.verifiedRecoveryKeys,
    HistoryRecoveryTransferService? transport,
    HistoryRecoveryCoordinator? coordinator,
  }) {
    _transport =
        transport ??
        HistoryRecoveryTransferService(
          api: api,
          baseUrl: baseUrl,
          token: token,
        );
    _coordinator =
        coordinator ??
        HistoryRecoveryCoordinator(
          cryptor: HistoryRecoveryCryptor(),
          transport: _transport,
        );
  }

  Future<HistoryRecoveryUiState> refresh() async {
    final keys = await verifiedRecoveryKeys();
    _keys = {for (final key in keys) key.deviceId: key};
    final localKey = _keys[localDeviceId];
    if (localKey == null) {
      throw const FormatException(
        'The local encrypted-history recovery key is unavailable.',
      );
    }
    if (await _resumePendingUpload(localKey)) return state;
    final ready = await _transport.available(
      channelId: channelId,
      destinationDeviceId: localDeviceId,
    );
    if (ready.isNotEmpty) {
      final transfer = ready.first;
      final context = HistoryRecoveryContext.fromManifest(transfer.manifest!);
      _pinDirectoryContext(context, localKey);
      _pendingTransfer = transfer;
      _retryReceive = true;
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.readyToRecover,
        deviceLabel: _deviceLabel(context.sourceDeviceId),
        firstServerSequence: transfer.firstServerSequence,
        lastServerSequence: transfer.lastServerSequence,
      );
      return state;
    }
    _pendingTransfer = null;
    if (eventStore.recoveryReceipts.isNotEmpty) {
      final receipt = eventStore.recoveryReceipts.last;
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.recovered,
        lastServerSequence: receipt.lastServerSequence,
      );
      return state;
    }
    final events = eventStore.events;
    if (_sharedDestinationId != null &&
        events.isNotEmpty &&
        _sharedLastSequence == events.last.serverSequence) {
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.shared,
        deviceLabel: _deviceLabel(_sharedDestinationId!),
        lastServerSequence: _sharedLastSequence,
      );
      return state;
    }
    final destinations = keys
        .where((key) => key.deviceId != localDeviceId)
        .map(
          (key) => HistoryRecoveryDestination(
            deviceId: key.deviceId,
            label: _deviceLabel(key.deviceId),
          ),
        )
        .toList(growable: false);
    if (events.isNotEmpty && destinations.isNotEmpty) {
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.approvalRequired,
        deviceLabel: destinations.length == 1
            ? destinations.single.label
            : null,
        firstServerSequence: events.first.serverSequence,
        lastServerSequence: events.last.serverSequence,
        destinations: destinations,
      );
    } else {
      state = const HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.beginsOnThisDevice,
      );
    }
    return state;
  }

  Future<bool> perform(String? destinationDeviceId) async {
    if (state.phase == HistoryRecoveryUiPhase.failed) {
      if (_retryReceive) return _receive();
      destinationDeviceId ??= _retryDestinationId;
    }
    if (state.phase == HistoryRecoveryUiPhase.readyToRecover) {
      return _receive();
    }
    if (state.phase != HistoryRecoveryUiPhase.approvalRequired &&
        state.phase != HistoryRecoveryUiPhase.failed) {
      return false;
    }
    final destination = _keys[destinationDeviceId];
    if (destination == null || destination.deviceId == localDeviceId) {
      throw const FormatException(
        'Select an enrolled encrypted-history destination.',
      );
    }
    _retryDestinationId = destination.deviceId;
    _retryReceive = false;
    final events = eventStore.events;
    if (events.isEmpty) return false;
    state = HistoryRecoveryUiState(
      phase: HistoryRecoveryUiPhase.transferring,
      deviceLabel: _deviceLabel(destination.deviceId),
      firstServerSequence: events.first.serverSequence,
      lastServerSequence: events.last.serverSequence,
    );
    try {
      final localRecovery = await recoveryIdentity.getOrCreate(
        serverId: serverId,
        deviceId: localDeviceId,
      );
      final account = await yuidIdentity.getOrCreateIdentity();
      final context = HistoryRecoveryContext(
        transferId: _newTransferId(),
        serverId: serverId,
        channelId: channelId,
        accountYuid: account.yuid,
        sourceDeviceId: localDeviceId,
        destinationDeviceId: destination.deviceId,
        sourceRecoveryPublicKey: localRecovery.publicKeyBase64Url,
        destinationRecoveryPublicKey: _encode(destination.publicKey.bytes),
        firstServerSequence: events.first.serverSequence,
        lastServerSequence: events.last.serverSequence,
        eventCount: events.length,
      );
      final sealed = await _coordinator.prepareUpload(
        context: context,
        eventStore: eventStore,
        destinationRecoveryPublicKey: destination.publicKey,
        sourceYuidKeyPair: await yuidIdentity.keyPair(),
      );
      await outbox.write(
        HistoryRecoveryOutboxEntry(context: context, sealed: sealed),
      );
      await _coordinator.uploadPrepared(context: context, sealed: sealed);
      await outbox.clear();
      _sharedDestinationId = destination.deviceId;
      _sharedLastSequence = events.last.serverSequence;
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.shared,
        deviceLabel: _deviceLabel(destination.deviceId),
        lastServerSequence: events.last.serverSequence,
      );
      return true;
    } catch (_) {
      state = const HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.failed,
        safeError:
            'Encrypted history could not be shared. No local history was changed.',
      );
      rethrow;
    }
  }

  Future<bool> _receive() async {
    final transfer = _pendingTransfer;
    if (transfer == null || transfer.manifest == null) return false;
    state = HistoryRecoveryUiState(
      phase: HistoryRecoveryUiPhase.transferring,
      deviceLabel: _deviceLabel(transfer.sourceDeviceId),
      firstServerSequence: transfer.firstServerSequence,
      lastServerSequence: transfer.lastServerSequence,
    );
    try {
      final context = HistoryRecoveryContext.fromManifest(transfer.manifest!);
      final localKey = _keys[localDeviceId];
      if (localKey == null) throw const FormatException();
      _pinDirectoryContext(context, localKey);
      final yuid = await yuidIdentity.getOrCreateIdentity();
      if (context.accountYuid != yuid.yuid) throw const FormatException();
      final merged = await _coordinator.downloadVerifyMergeAndConsume(
        expectedContext: context,
        transfer: transfer,
        destinationRecoveryKeyPair: await recoveryIdentity.keyPair(
          serverId: serverId,
          deviceId: localDeviceId,
        ),
        authorizedSourceYuidPublicKey: SimplePublicKey(
          _decode(yuid.publicKeyBase64Url),
          type: KeyPairType.ed25519,
        ),
        historicalCredentials: historicalCredentials,
        eventStore: eventStore,
      );
      _retryReceive = false;
      state = HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.recovered,
        lastServerSequence: transfer.lastServerSequence,
      );
      return merged;
    } catch (_) {
      state = const HistoryRecoveryUiState(
        phase: HistoryRecoveryUiPhase.failed,
        safeError:
            'Recovery failed authentication. No history was changed or hidden.',
      );
      rethrow;
    }
  }

  Future<bool> _resumePendingUpload(
    VerifiedHistoryRecoveryDeviceKey localKey,
  ) async {
    final pending = await outbox.read();
    if (pending == null) return false;
    final context = pending.context;
    final destination = _keys[context.destinationDeviceId];
    final localIdentity = await recoveryIdentity.getOrCreate(
      serverId: serverId,
      deviceId: localDeviceId,
    );
    final account = await yuidIdentity.getOrCreateIdentity();
    if (context.serverId != serverId ||
        context.channelId != channelId ||
        context.sourceDeviceId != localDeviceId ||
        context.accountYuid != account.yuid ||
        destination == null ||
        !_sameBytes(
          localKey.publicKey.bytes,
          _decode(localIdentity.publicKeyBase64Url),
        ) ||
        !_sameBytes(
          destination.publicKey.bytes,
          _decode(context.destinationRecoveryPublicKey),
        ) ||
        context.sourceRecoveryPublicKey != localIdentity.publicKeyBase64Url) {
      throw const FormatException(
        'Pending encrypted-history upload context is no longer authorized.',
      );
    }
    state = HistoryRecoveryUiState(
      phase: HistoryRecoveryUiPhase.transferring,
      deviceLabel: _deviceLabel(destination.deviceId),
      firstServerSequence: context.firstServerSequence,
      lastServerSequence: context.lastServerSequence,
    );
    await _coordinator.uploadPrepared(context: context, sealed: pending.sealed);
    await outbox.clear();
    _sharedDestinationId = destination.deviceId;
    _sharedLastSequence = context.lastServerSequence;
    state = HistoryRecoveryUiState(
      phase: HistoryRecoveryUiPhase.shared,
      deviceLabel: _deviceLabel(destination.deviceId),
      lastServerSequence: context.lastServerSequence,
    );
    return true;
  }

  Future<void> close() => outbox.close();

  void _pinDirectoryContext(
    HistoryRecoveryContext context,
    VerifiedHistoryRecoveryDeviceKey localKey,
  ) {
    final source = _keys[context.sourceDeviceId];
    if (context.serverId != serverId ||
        context.channelId != channelId ||
        context.destinationDeviceId != localDeviceId ||
        source == null ||
        !_sameBytes(
          source.publicKey.bytes,
          _decode(context.sourceRecoveryPublicKey),
        ) ||
        !_sameBytes(
          localKey.publicKey.bytes,
          _decode(context.destinationRecoveryPublicKey),
        )) {
      throw const FormatException(
        'Encrypted-history device context was substituted.',
      );
    }
  }

  String _deviceLabel(String deviceId) =>
      'Device ••••${deviceId.substring(deviceId.length - 4)}';

  String _newTransferId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    return 'recovery_${_encode(bytes)}';
  }

  String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  Uint8List _decode(String value) => Uint8List.fromList(
    base64Url.decode(
      value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
    ),
  );
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
