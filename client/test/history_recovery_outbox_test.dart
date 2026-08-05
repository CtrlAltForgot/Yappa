import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
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

HistoryRecoveryOutboxEntry _entry() => HistoryRecoveryOutboxEntry(
  context: const HistoryRecoveryContext(
    transferId: 'recovery_abcdefghijklmnopqrstuv',
    serverId: 'server-id',
    channelId: '1',
    accountYuid: 'abcdefghijklmnopqrst',
    sourceDeviceId: 'device_ssssssssssssssssssssssss',
    destinationDeviceId: 'device_dddddddddddddddddddddddd',
    sourceRecoveryPublicKey: 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
    destinationRecoveryPublicKey: 'zyxwvutsrqponmlkjihgfedcbaABCDEFGHIJKLMNOPQ',
    firstServerSequence: 1,
    lastServerSequence: 3,
    eventCount: 2,
  ),
  sealed: SealedHistoryRecoveryTransfer(
    manifest: Uint8List.fromList([1, 2, 3]),
    manifestSha256: '0' * 64,
    yuidSignature: 'a' * 86,
    chunks: [
      Uint8List.fromList([4, 5, 6]),
      Uint8List.fromList([7, 8, 9]),
    ],
  ),
);

String _encode(List<int> value) => base64Url.encode(value).replaceAll('=', '');

Uint8List _decode(String value) => Uint8List.fromList(
  base64Url.decode(
    value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encrypted recovery upload survives restart exactly', () async {
    final root = await Directory.systemTemp.createTemp('yappa-history-outbox-');
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final first = await HistoryRecoveryOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'s' * 24}',
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await first.write(_entry());
    await first.close();

    final second = await HistoryRecoveryOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'s' * 24}',
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final restored = await second.read();
    expect(restored?.context.transferId, _entry().context.transferId);
    expect(restored?.context.eventCount, 2);
    expect(restored?.sealed.manifest, [1, 2, 3]);
    expect(restored?.sealed.chunks, [
      [4, 5, 6],
      [7, 8, 9],
    ]);
    await second.clear();
    expect(await second.read(), isNull);
    await second.close();
  });

  test('reads a protected v1 JSON outbox after the binary upgrade', () async {
    final root = await Directory.systemTemp.createTemp(
      'yappa-history-outbox-v1-',
    );
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final first = await HistoryRecoveryOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'s' * 24}',
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await first.write(_entry());
    await first.close();
    final file = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere(
          (item) => item.path.endsWith('history-recovery-outbox.v1.bin'),
        );
    final entry = _entry();
    final legacyPlaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'context': {
            'accountYuid': entry.context.accountYuid,
            'channelId': entry.context.channelId,
            'destinationDeviceId': entry.context.destinationDeviceId,
            'destinationRecoveryPublicKey':
                entry.context.destinationRecoveryPublicKey,
            'eventCount': entry.context.eventCount,
            'firstServerSequence': entry.context.firstServerSequence,
            'lastServerSequence': entry.context.lastServerSequence,
            'serverId': entry.context.serverId,
            'sourceDeviceId': entry.context.sourceDeviceId,
            'sourceRecoveryPublicKey': entry.context.sourceRecoveryPublicKey,
            'transferId': entry.context.transferId,
          },
          'manifest': _encode(entry.sealed.manifest),
          'manifestSha256': entry.sealed.manifestSha256,
          'yuidSignature': entry.sealed.yuidSignature,
          'chunks': entry.sealed.chunks.map(_encode).toList(growable: false),
          'version': 1,
        }),
      ),
    );
    final key = _decode(secrets.values.values.single);
    final scope = hashes.sha256
        .convert(utf8.encode('server-id|device_${'s' * 24}|1'))
        .toString();
    final box = await AesGcm.with256bits().encrypt(
      legacyPlaintext,
      secretKey: SecretKey(key),
      aad: utf8.encode(
        'yappa-history-recovery-outbox-v1|server-id|'
        'device_${'s' * 24}|1',
      ),
    );
    final protected =
        Uint8List(
            box.nonce.length + box.cipherText.length + box.mac.bytes.length,
          )
          ..setRange(0, box.nonce.length, box.nonce)
          ..setRange(
            box.nonce.length,
            box.nonce.length + box.cipherText.length,
            box.cipherText,
          )
          ..setRange(
            box.nonce.length + box.cipherText.length,
            box.nonce.length + box.cipherText.length + box.mac.bytes.length,
            box.mac.bytes,
          );
    expect(file.path, contains(scope));
    await file.writeAsBytes(protected, flush: true);

    final migrated = await HistoryRecoveryOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'s' * 24}',
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final restored = await migrated.read();
    expect(restored?.context.transferId, entry.context.transferId);
    expect(restored?.sealed.chunks, entry.sealed.chunks);
    await migrated.clear();
    await migrated.close();
  });

  test('tampered recovery outbox fails closed', () async {
    final root = await Directory.systemTemp.createTemp(
      'yappa-history-outbox-tamper-',
    );
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final outbox = await HistoryRecoveryOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'s' * 24}',
      channelId: '1',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await outbox.write(_entry());
    await outbox.close();
    final file = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere(
          (item) => item.path.endsWith('history-recovery-outbox.v1.bin'),
        );
    final bytes = await file.readAsBytes();
    bytes[14] ^= 1;
    await file.writeAsBytes(bytes, flush: true);
    await expectLater(
      HistoryRecoveryOutbox.open(
        serverId: 'server-id',
        deviceId: 'device_${'s' * 24}',
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => root,
      ),
      throwsA(isA<HistoryRecoveryOutboxException>()),
    );
  });
}
