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
}
