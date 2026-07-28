import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/mls_native.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  final supportsMlsBridge =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  test(
    'native MLS bridge joins, persists, and excludes removed devices',
    () {
      final alice = MlsNativeDevice.create(bytes('server|alice|device-a'));
      final bob = MlsNativeDevice.create(bytes('server|bob|device-b'));
      final groupId = bytes('yappa-text-v1|server|42');
      final wrappingKey = Uint8List.fromList(List<int>.filled(32, 7));
      final stateContext = bytes('server|device-b');

      addTearDown(alice.close);
      addTearDown(bob.close);

      expect(alice.signaturePublicKey, hasLength(32));
      expect(bob.signaturePublicKey, hasLength(32));
      expect(alice.createGroup(groupId), 0);

      final add = alice.prepareAdd(groupId, bob.generateKeyPackage());
      expect(add.parentEpoch, 0);
      expect(add.acceptedEpoch, 1);
      expect(alice.acceptPendingCommit(groupId), 1);
      expect(bob.joinWelcome(groupId, add.welcome), 1);
      final aliceMembers = alice.groupMembers(groupId);
      expect(aliceMembers, hasLength(2));
      expect(
        aliceMembers.map((member) => utf8.decode(member.credential)),
        containsAll(['server|alice|device-a', 'server|bob|device-b']),
      );
      expect(
        aliceMembers.every((member) => member.signaturePublicKey.length == 32),
        isTrue,
      );

      final first = alice.encryptApplication(groupId, bytes('private'));
      expect(
        utf8.decode(bob.decryptApplication(groupId, first).plaintext),
        'private',
      );

      final encryptedState = bob.exportState(
        wrappingKey: wrappingKey,
        context: stateContext,
      );
      final restored = MlsNativeDevice.restore(
        wrappingKey: wrappingKey,
        context: stateContext,
        encryptedState: encryptedState,
      );
      addTearDown(restored.close);
      expect(restored.epoch(groupId), 1);

      final removal = alice.prepareRemove(
        groupId,
        bytes('server|bob|device-b'),
      );
      expect(alice.acceptPendingCommit(groupId), 2);
      expect(restored.processCommit(groupId, removal.commit), 2);

      final future = alice.encryptApplication(groupId, bytes('future'));
      expect(
        () => restored.decryptApplication(groupId, future),
        throwsA(isA<MlsNativeException>()),
      );
    },
    skip: !supportsMlsBridge,
  );

  test(
    'native MLS state fails closed for a wrong context or key',
    () {
      final device = MlsNativeDevice.create(bytes('server|alice|device'));
      final key = Uint8List.fromList(List<int>.filled(32, 11));
      final context = bytes('server|device');
      addTearDown(device.close);

      final encrypted = device.exportState(wrappingKey: key, context: context);
      expect(
        () => MlsNativeDevice.restore(
          wrappingKey: key,
          context: bytes('other-server|device'),
          encryptedState: encrypted,
        ),
        throwsA(isA<MlsNativeException>()),
      );
      expect(
        () => MlsNativeDevice.restore(
          wrappingKey: Uint8List.fromList(List<int>.filled(32, 12)),
          context: context,
          encryptedState: encrypted,
        ),
        throwsA(isA<MlsNativeException>()),
      );
    },
    skip: !supportsMlsBridge,
  );
}
