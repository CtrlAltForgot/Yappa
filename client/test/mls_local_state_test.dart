import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_native.dart';
import 'package:yappa/data/secret_storage.dart';

class MemorySecretStorage implements SecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsMlsBridge = Platform.isLinux || Platform.isWindows;

  test('encrypted MLS state survives a local restart', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('yappa-mls-state-');
    final secrets = MemorySecretStorage();
    addTearDown(() => root.delete(recursive: true));

    final first = await MlsLocalDevice.open(
      serverId: 'server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    final groupId = Uint8List.fromList('group-id'.codeUnits);
    expect(await first.mutate((native) => native.createGroup(groupId)), 0);
    expect(await first.read((native) => native.epoch(groupId)), 0);
    await first.close();

    final restored = await MlsLocalDevice.open(
      serverId: 'server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    addTearDown(restored.close);
    expect(await restored.read((native) => native.epoch(groupId)), 0);

    final stateFiles = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('state.v1.bin'))
        .toList();
    expect(stateFiles, hasLength(1));
    if (Platform.isLinux) {
      final mode = (await Process.run('stat', [
        '-c',
        '%a',
        stateFiles.single.path,
      ])).stdout.toString().trim();
      expect(mode, '600');
    }
  }, skip: !supportsMlsBridge);

  test('missing OS wrapping key fails closed', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('yappa-mls-state-');
    final secrets = MemorySecretStorage();
    addTearDown(() => root.delete(recursive: true));

    final first = await MlsLocalDevice.open(
      serverId: 'server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    await first.close();
    secrets.values.removeWhere((key, _) => key.contains('mls_wrapping_key'));

    expect(
      () => MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: secrets,
        supportDirectory: () async => root,
      ),
      throwsA(isA<MlsLocalStateException>()),
    );
  }, skip: !supportsMlsBridge);

  test('failed local MLS mutation restores the prior native state', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('yappa-mls-state-');
    final secrets = MemorySecretStorage();
    addTearDown(() => root.delete(recursive: true));
    final local = await MlsLocalDevice.open(
      serverId: 'server-id',
      secretStorage: secrets,
      supportDirectory: () async => root,
    );
    addTearDown(local.close);
    final rejectedGroup = Uint8List.fromList('rejected-group'.codeUnits);

    await expectLater(
      local.mutate((native) {
        native.createGroup(rejectedGroup);
        throw const FormatException('reject post-operation validation');
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => local.read((native) => native.epoch(rejectedGroup)),
      throwsA(isA<MlsNativeException>()),
    );
  }, skip: !supportsMlsBridge);
}
