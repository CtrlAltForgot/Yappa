import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/media_key_envelope.dart';

void main() {
  test(
    'sealed media keys round trip only for the bound device context',
    () async {
      final agreement = X25519();
      final signatures = Ed25519();
      final recipient = await agreement.newKeyPair();
      final recipientPublic = await recipient.extractPublicKey();
      final senderYuid = await signatures.newKeyPair();
      final senderYuidPublic = await senderYuid.extractPublicKey();
      final cryptor = MediaKeyEnvelopeCryptor();
      const context = MediaRoomContext(
        serverId: 'node_test',
        channelId: 'voice_7',
        epoch: 4,
        senderDeviceId: 'device_sender',
        recipientDeviceId: 'device_recipient',
      );
      final roomKey = Uint8List.fromList(
        List<int>.generate(32, (index) => index),
      );
      final createdAt = DateTime.utc(2026, 7, 24, 12, 30);

      final envelope = await cryptor.seal(
        context: context,
        messageSequence: 1,
        roomKey: roomKey,
        keyIndex: 3,
        createdAt: createdAt,
        recipientMediaPublicKey: recipientPublic,
        senderYuidKeyPair: senderYuid,
      );
      final serialized = MediaKeyEnvelope.fromJson(envelope.toJson());
      final opened = await cryptor.open(
        envelope: serialized,
        expectedContext: context,
        recipientMediaKeyPair: recipient,
        authorizedSenderYuidPublicKey: senderYuidPublic,
      );

      expect(opened.roomKey, roomKey);
      expect(opened.keyIndex, 3);
      expect(opened.createdAt, createdAt);

      const wrongRecipient = MediaRoomContext(
        serverId: 'node_test',
        channelId: 'voice_7',
        epoch: 4,
        senderDeviceId: 'device_sender',
        recipientDeviceId: 'different_device',
      );
      await expectLater(
        cryptor.open(
          envelope: serialized,
          expectedContext: wrongRecipient,
          recipientMediaKeyPair: recipient,
          authorizedSenderYuidPublicKey: senderYuidPublic,
        ),
        throwsFormatException,
      );
    },
  );

  test('tampering and unauthorized sender signatures are rejected', () async {
    final agreement = X25519();
    final signatures = Ed25519();
    final recipient = await agreement.newKeyPair();
    final sender = await signatures.newKeyPair();
    final attacker = await signatures.newKeyPair();
    final cryptor = MediaKeyEnvelopeCryptor();
    const context = MediaRoomContext(
      serverId: 'node_test',
      channelId: 'voice_9',
      epoch: 2,
      senderDeviceId: 'sender',
      recipientDeviceId: 'recipient',
    );
    final envelope = await cryptor.seal(
      context: context,
      messageSequence: 7,
      roomKey: Uint8List.fromList(List<int>.filled(32, 42)),
      keyIndex: 1,
      createdAt: DateTime.utc(2026, 7, 24),
      recipientMediaPublicKey: await recipient.extractPublicKey(),
      senderYuidKeyPair: sender,
    );

    await expectLater(
      cryptor.open(
        envelope: envelope,
        expectedContext: context,
        recipientMediaKeyPair: recipient,
        authorizedSenderYuidPublicKey: await attacker.extractPublicKey(),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    final ciphertext = envelope.ciphertext;
    final tampered = MediaKeyEnvelope(
      protocol: envelope.protocol,
      serverId: envelope.serverId,
      channelId: envelope.channelId,
      epoch: envelope.epoch,
      messageSequence: envelope.messageSequence,
      senderDeviceId: envelope.senderDeviceId,
      recipientDeviceId: envelope.recipientDeviceId,
      ephemeralPublicKey: envelope.ephemeralPublicKey,
      nonce: envelope.nonce,
      ciphertext:
          '${ciphertext.substring(0, ciphertext.length - 1)}'
          '${ciphertext.endsWith('A') ? 'B' : 'A'}',
      authenticationTag: envelope.authenticationTag,
      signature: envelope.signature,
    );
    await expectLater(
      cryptor.open(
        envelope: tampered,
        expectedContext: context,
        recipientMediaKeyPair: recipient,
        authorizedSenderYuidPublicKey: await sender.extractPublicKey(),
      ),
      throwsA(anything),
    );
  });
}
