import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/history_recovery_crypto.dart';
import 'package:yappa/data/history_recovery_outbox.dart';
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

String _encode(List<int> value) => base64Url.encode(value).replaceAll('=', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'seals, persists, reopens, and decrypts a near-ceiling transfer',
    () async {
      final stopwatch = Stopwatch()..start();
      final root = await Directory.systemTemp.createTemp(
        'yappa-history-recovery-capacity-',
      );
      addTearDown(() => root.delete(recursive: true));
      final secrets = _MemorySecrets();
      final destination = await X25519().newKeyPair();
      final destinationPublic = await destination.extractPublicKey();
      final sourceRecovery = await X25519().newKeyPair();
      final sourcePublic = await sourceRecovery.extractPublicKey();
      final yuid = await Ed25519().newKeyPair();
      final context = HistoryRecoveryContext(
        transferId: 'recovery_abcdefghijklmnopqrstuv',
        serverId: 'capacity-server',
        channelId: '1',
        accountYuid: 'abcdefghijklmnopqrst',
        sourceDeviceId: 'device_${'s' * 24}',
        destinationDeviceId: 'device_${'d' * 24}',
        sourceRecoveryPublicKey: _encode(sourcePublic.bytes),
        destinationRecoveryPublicKey: _encode(destinationPublic.bytes),
        firstServerSequence: 1,
        lastServerSequence: 50000,
        eventCount: 50000,
      );
      const payloadBytes = 60 * 1024 * 1024;
      final payload = Uint8List(payloadBytes);
      for (var index = 0; index < payload.length; index += 4096) {
        payload[index] = (index ~/ 4096) % 251;
      }
      final cryptor = HistoryRecoveryCryptor();
      final sealed = await cryptor.seal(
        context: context,
        canonicalRecords: payload,
        destinationRecoveryPublicKey: destinationPublic,
        sourceYuidKeyPair: yuid,
      );
      final ciphertextBytes = sealed.chunks.fold<int>(
        0,
        (total, chunk) => total + chunk.length,
      );
      expect(sealed.chunks, hasLength(241));
      expect(
        ciphertextBytes,
        lessThanOrEqualTo(HistoryRecoveryCryptor.maxCiphertextBytes),
      );

      final outbox = await HistoryRecoveryOutbox.open(
        serverId: context.serverId,
        deviceId: context.sourceDeviceId,
        channelId: context.channelId,
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      await outbox.write(
        HistoryRecoveryOutboxEntry(context: context, sealed: sealed),
      );
      await outbox.close();
      final outboxFile = root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere(
            (file) => file.path.endsWith('history-recovery-outbox.v1.bin'),
          );
      final outboxBytes = await outboxFile.length();
      expect(outboxBytes, lessThan(96 * 1024 * 1024));

      final reopened = await HistoryRecoveryOutbox.open(
        serverId: context.serverId,
        deviceId: context.sourceDeviceId,
        channelId: context.channelId,
        secretStorage: secrets,
        supportDirectory: () async => root,
      );
      final restored = await reopened.read();
      expect(restored, isNotNull);
      expect(restored!.sealed.chunks, hasLength(sealed.chunks.length));
      final plaintext = await cryptor.open(
        expectedContext: context,
        transfer: restored.sealed,
        destinationRecoveryKeyPair: destination,
        authorizedSourceYuidPublicKey: await yuid.extractPublicKey(),
      );
      expect(plaintext.length, payloadBytes);
      expect(plaintext[0], payload[0]);
      expect(plaintext[4096 * 12000], payload[4096 * 12000]);
      expect(plaintext.last, payload.last);
      await reopened.clear();
      await reopened.close();
      stopwatch.stop();
      // Kept visible in the opt-in release evidence log.
      // ignore: avoid_print
      print(
        'history-recovery-capacity '
        'payload=$payloadBytes ciphertext=$ciphertextBytes '
        'outbox=$outboxBytes '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      payload.fillRange(0, payload.length, 0);
      plaintext.fillRange(0, plaintext.length, 0);
    },
    skip: Platform.environment['YAPPA_RUN_RECOVERY_CAPACITY'] != '1'
        ? 'Set YAPPA_RUN_RECOVERY_CAPACITY=1 for the release scale gate.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
