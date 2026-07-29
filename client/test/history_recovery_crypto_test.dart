import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/history_recovery_crypto.dart';

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decode(String value) => Uint8List.fromList(
  base64Url.decode(
    value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
  ),
);

void main() {
  test(
    'round trips bounded signed recovery chunks and rejects tampering',
    () async {
      final x25519 = X25519();
      final ed25519 = Ed25519();
      final sourceRecovery = await x25519.newKeyPair();
      final destinationRecovery = await x25519.newKeyPair();
      final destinationPublic = await destinationRecovery.extractPublicKey();
      final yuidKeys = await ed25519.newKeyPair();
      const context = HistoryRecoveryContext(
        transferId: 'recovery_abcdefghijklmnopqrstuv',
        serverId: 'srv_recovery_crypto',
        channelId: '42',
        accountYuid: 'abcdefghijklmnopqrst',
        sourceDeviceId: 'device_abcdefghijklmnopqrstuvwx',
        destinationDeviceId: 'device_yxwvutsrqponmlkjihgfedcb',
        sourceRecoveryPublicKey: '',
        destinationRecoveryPublicKey: '',
        firstServerSequence: 1,
        lastServerSequence: 3,
        eventCount: 2,
      );
      final boundContext = HistoryRecoveryContext(
        transferId: context.transferId,
        serverId: context.serverId,
        channelId: context.channelId,
        accountYuid: context.accountYuid,
        sourceDeviceId: context.sourceDeviceId,
        destinationDeviceId: context.destinationDeviceId,
        sourceRecoveryPublicKey: _encode(
          (await sourceRecovery.extractPublicKey()).bytes,
        ),
        destinationRecoveryPublicKey: _encode(destinationPublic.bytes),
        firstServerSequence: context.firstServerSequence,
        lastServerSequence: context.lastServerSequence,
        eventCount: context.eventCount,
      );
      final plaintext = Uint8List(300000);
      for (var index = 0; index < plaintext.length; index += 1) {
        plaintext[index] = index % 251;
      }
      final cryptor = HistoryRecoveryCryptor();
      final sealed = await cryptor.seal(
        context: boundContext,
        canonicalRecords: plaintext,
        destinationRecoveryPublicKey: destinationPublic,
        sourceYuidKeyPair: yuidKeys,
      );

      expect(sealed.chunks, hasLength(2));
      expect(
        sealed.chunks.every(
          (chunk) =>
              chunk.length <= HistoryRecoveryCryptor.maxCiphertextChunkBytes,
        ),
        true,
      );
      expect(
        await cryptor.open(
          expectedContext: boundContext,
          transfer: sealed,
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        plaintext,
      );

      final tamperedChunk = Uint8List.fromList(sealed.chunks.first);
      tamperedChunk[tamperedChunk.length ~/ 2] ^= 1;
      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: SealedHistoryRecoveryTransfer(
            manifest: sealed.manifest,
            manifestSha256: sealed.manifestSha256,
            yuidSignature: sealed.yuidSignature,
            chunks: [tamperedChunk, sealed.chunks.last],
          ),
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final substitutedContext = HistoryRecoveryContext(
        transferId: boundContext.transferId,
        serverId: boundContext.serverId,
        channelId: '43',
        accountYuid: boundContext.accountYuid,
        sourceDeviceId: boundContext.sourceDeviceId,
        destinationDeviceId: boundContext.destinationDeviceId,
        sourceRecoveryPublicKey: boundContext.sourceRecoveryPublicKey,
        destinationRecoveryPublicKey: boundContext.destinationRecoveryPublicKey,
        firstServerSequence: boundContext.firstServerSequence,
        lastServerSequence: boundContext.lastServerSequence,
        eventCount: boundContext.eventCount,
      );
      await expectLater(
        cryptor.open(
          expectedContext: substitutedContext,
          transfer: sealed,
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<FormatException>()),
      );

      final wrongDestination = await x25519.newKeyPair();
      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: sealed,
          destinationRecoveryKeyPair: wrongDestination,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final wrongYuid = await ed25519.newKeyPair();
      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: sealed,
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await wrongYuid.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: SealedHistoryRecoveryTransfer(
            manifest: sealed.manifest,
            manifestSha256: sealed.manifestSha256,
            yuidSignature: sealed.yuidSignature,
            chunks: [sealed.chunks.last, sealed.chunks.first],
          ),
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: SealedHistoryRecoveryTransfer(
            manifest: sealed.manifest,
            manifestSha256: sealed.manifestSha256,
            yuidSignature: sealed.yuidSignature,
            chunks: [
              Uint8List.sublistView(
                sealed.chunks.first,
                0,
                sealed.chunks.first.length - 1,
              ),
              sealed.chunks.last,
            ],
          ),
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final alteredSignature = _decode(sealed.yuidSignature)..[0] ^= 1;
      await expectLater(
        cryptor.open(
          expectedContext: boundContext,
          transfer: SealedHistoryRecoveryTransfer(
            manifest: sealed.manifest,
            manifestSha256: sealed.manifestSha256,
            yuidSignature: _encode(alteredSignature),
            chunks: sealed.chunks,
          ),
          destinationRecoveryKeyPair: destinationRecovery,
          authorizedSourceYuidPublicKey: await yuidKeys.extractPublicKey(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );
}
