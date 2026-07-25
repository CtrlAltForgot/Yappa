import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/mls_outbox.dart';
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

MlsAddOutboxEntry _entry({MlsAddOutboxStage? stage}) => MlsAddOutboxEntry(
  channelId: '1',
  recipientDeviceId: 'device_${'a' * 24}',
  parentEpoch: 0,
  acceptedEpoch: 1,
  commitOperationId: 'mlsop_${'b' * 22}',
  welcomeOperationId: 'mlsop_${'c' * 22}',
  commit: Uint8List.fromList([1, 2, 3]),
  welcome: Uint8List.fromList([4, 5, 6]),
  stage: stage ?? MlsAddOutboxStage.commitPending,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encrypted MLS outbox survives restart and stage transition', () async {
    final root = await Directory.systemTemp.createTemp('yappa-mls-outbox-');
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final first = await MlsOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'d' * 24}',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await first.write(_entry());
    await first.close();

    final second = await MlsOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'d' * 24}',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final restored = await second.read();
    expect(restored?.commitOperationId, 'mlsop_${'b' * 22}');
    expect(restored?.commit, [1, 2, 3]);
    await second.write(restored!.welcomePending());
    expect((await second.read())?.stage, MlsAddOutboxStage.welcomePending);
    await second.clear();
    expect(await second.read(), isNull);
    await second.close();
  });

  test('tampered MLS outbox fails closed', () async {
    final root = await Directory.systemTemp.createTemp('yappa-mls-outbox-');
    final secrets = _MemorySecrets();
    addTearDown(() => root.delete(recursive: true));
    final outbox = await MlsOutbox.open(
      serverId: 'server-id',
      deviceId: 'device_${'d' * 24}',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await outbox.write(_entry());
    await outbox.close();
    final file = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('add-outbox.v1.bin'));
    final bytes = await file.readAsBytes();
    bytes[15] ^= 1;
    await file.writeAsBytes(bytes, flush: true);

    expect(
      () => MlsOutbox.open(
        serverId: 'server-id',
        deviceId: 'device_${'d' * 24}',
        secretStorage: secrets,
        supportDirectory: () async => root,
      ),
      throwsA(isA<MlsOutboxException>()),
    );
  });
}
