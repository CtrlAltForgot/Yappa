import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
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

MlsApplicationEvent _event() => MlsApplicationEvent(
  serverSequence: 1,
  epoch: 0,
  eventId: 'a' * 22,
  channelId: '1',
  kind: EncryptedApplicationEventKind.message,
  targetEventId: null,
  createdAt: DateTime.utc(2026),
  body: const {'content': 'encrypted locally'},
  senderCredential: Uint8List.fromList([1, 2, 3]),
  senderSignaturePublicKey: Uint8List.fromList(List<int>.filled(32, 4)),
);

MlsApplicationEvent _historyEvent({
  required int sequence,
  required String eventId,
  EncryptedApplicationEventKind kind = EncryptedApplicationEventKind.message,
  String? targetEventId,
  Map<String, dynamic> body = const {'content': 'recovered'},
  int credential = 7,
}) => MlsApplicationEvent(
  serverSequence: sequence,
  epoch: 2,
  eventId: eventId,
  channelId: '1',
  kind: kind,
  targetEventId: targetEventId,
  createdAt: DateTime.utc(2026, 7, 28, 12, sequence),
  body: body,
  senderCredential: Uint8List.fromList([credential]),
  senderSignaturePublicKey: Uint8List.fromList(
    List<int>.filled(32, credential),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'encrypted MLS history survives restart and rejects tampering',
    () async {
      final root = await Directory.systemTemp.createTemp('yappa-mls-events-');
      final secrets = _MemorySecrets();
      addTearDown(() => root.delete(recursive: true));
      final first = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      await first.apply(_event(), senderIsOwner: false);
      await first.close();

      final restored = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      expect(restored.events.single.body['content'], 'encrypted locally');
      await restored.close();

      final file = root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((item) => item.path.endsWith('events.v1.bin'));
      final bytes = await file.readAsBytes();
      bytes[14] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      expect(
        () => MlsEventStore.open(
          serverId: 'server-id',
          deviceId: 'device_${'d' * 24}',
          channelId: '1',
          secretStorage: secrets,
          supportDirectory: () async => root,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'exports and atomically merges authenticated recovery records',
    () async {
      final root = await Directory.systemTemp.createTemp('yappa-mls-recovery-');
      final secrets = _MemorySecrets();
      addTearDown(() => root.delete(recursive: true));
      final source = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'s' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      final originalId = 'm' * 22;
      await source.apply(
        _historyEvent(sequence: 1, eventId: originalId),
        senderIsOwner: false,
      );
      await source.apply(
        _historyEvent(
          sequence: 3,
          eventId: 'e' * 22,
          kind: EncryptedApplicationEventKind.edit,
          targetEventId: originalId,
          body: const {'content': 'edited after recovery'},
        ),
        senderIsOwner: false,
      );
      final records = source.exportRecoveryRecords(
        firstServerSequence: 1,
        lastServerSequence: 3,
      );
      await source.close();

      final destination = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      const receipt = MlsHistoryRecoveryReceipt(
        transferId: 'recovery_abcdefghijklmnopqrstuv',
        manifestSha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        sourceDeviceId: 'device_ssssssssssssssssssssssss',
        destinationDeviceId: 'device_dddddddddddddddddddddddd',
        firstServerSequence: 1,
        lastServerSequence: 3,
        eventCount: 2,
      );
      var authorizationChecks = 0;
      expect(
        await destination.mergeRecoveryRecords(
          canonicalRecords: records,
          receipt: receipt,
          authorizeSender: (event) async {
            authorizationChecks += 1;
            return const MlsRecoveredSenderAuthorization(
              authorized: true,
              senderIsOwner: false,
            );
          },
        ),
        isTrue,
      );
      expect(authorizationChecks, 2);
      expect(destination.events.map((event) => event.serverSequence), [1, 3]);
      expect(
        destination.recoveryReceipts.single.transferId,
        receipt.transferId,
      );
      expect(
        await destination.mergeRecoveryRecords(
          canonicalRecords: records,
          receipt: receipt,
          authorizeSender: (_) async =>
              throw StateError('Exact replay must not be reprocessed.'),
        ),
        isFalse,
      );
      await destination.close();

      final restored = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      expect(restored.events, hasLength(2));
      expect(
        restored.recoveryReceipts.single.manifestSha256,
        receipt.manifestSha256,
      );
      await restored.close();
    },
  );

  test(
    'rejects unauthorized recovered senders without a partial merge',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'yappa-mls-recovery-denied-',
      );
      final secrets = _MemorySecrets();
      addTearDown(() => root.delete(recursive: true));
      final source = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'s' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      await source.apply(
        _historyEvent(sequence: 1, eventId: 'm' * 22),
        senderIsOwner: false,
      );
      final records = source.exportRecoveryRecords(
        firstServerSequence: 1,
        lastServerSequence: 1,
      );
      final destination = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      await expectLater(
        destination.mergeRecoveryRecords(
          canonicalRecords: records,
          receipt: const MlsHistoryRecoveryReceipt(
            transferId: 'recovery_zyxwvutsrqponmlkjihgfe',
            manifestSha256:
                'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
            sourceDeviceId: 'device_ssssssssssssssssssssssss',
            destinationDeviceId: 'device_dddddddddddddddddddddddd',
            firstServerSequence: 1,
            lastServerSequence: 1,
            eventCount: 1,
          ),
          authorizeSender: (_) async => const MlsRecoveredSenderAuthorization(
            authorized: false,
            senderIsOwner: false,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(destination.events, isEmpty);
      expect(destination.recoveryReceipts, isEmpty);
      await source.close();
      await destination.close();
    },
  );
}
