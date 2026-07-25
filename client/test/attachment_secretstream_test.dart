import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/attachment_secretstream.dart';

void main() {
  late Directory directory;
  late AttachmentSecretstream secretstream;
  const context = AttachmentEncryptionContext(
    serverId: 'server-test',
    channelId: '42',
    eventId: 'AAAAAAAAAAAAAAAAAAAAAA',
    attachmentId: 'eatt_BBBBBBBBBBBBBBBBBBBBBB',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yappa-secretstream-test-',
    );
    secretstream = AttachmentSecretstream();
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'round trips empty and multichunk files with final authentication',
    () async {
      for (final plaintext in [
        Uint8List(0),
        Uint8List.fromList(
          List<int>.generate(
            attachmentSecretstreamChunkBytes * 2 + 73,
            (index) => index % 251,
          ),
        ),
      ]) {
        final suffix = plaintext.isEmpty ? 'empty' : 'multi';
        final input = File('${directory.path}/$suffix.input');
        final encryptedPath = '${directory.path}/$suffix.ciphertext';
        final decryptedPath = '${directory.path}/$suffix.output';
        await input.writeAsBytes(plaintext, flush: true);

        final encrypted = await secretstream.encryptFile(
          plaintextPath: input.path,
          ciphertextPath: encryptedPath,
          context: context,
        );
        expect(encrypted.key.length, 32);
        expect(encrypted.header.length, 24);
        expect(encrypted.ciphertextSizeBytes, greaterThanOrEqualTo(17));
        expect(encrypted.chunkCount, plaintext.isEmpty ? 1 : 3);

        await secretstream.decryptFile(
          ciphertextPath: encrypted.ciphertextPath,
          plaintextPath: decryptedPath,
          key: encrypted.key,
          header: encrypted.header,
          expectedCiphertextSha256: encrypted.ciphertextSha256,
          expectedChunkCount: encrypted.chunkCount,
          context: context,
        );
        expect(await File(decryptedPath).readAsBytes(), plaintext);
      }
    },
  );

  test('tampering, truncation, and context substitution fail closed', () async {
    final input = File('${directory.path}/input');
    await input.writeAsBytes(
      List<int>.generate(
        attachmentSecretstreamChunkBytes + 31,
        (index) => index % 239,
      ),
      flush: true,
    );
    final encrypted = await secretstream.encryptFile(
      plaintextPath: input.path,
      ciphertextPath: '${directory.path}/ciphertext',
      context: context,
    );
    final original = await File(encrypted.ciphertextPath).readAsBytes();

    final cases = <String, Uint8List>{
      'tampered': Uint8List.fromList(original)..[10] ^= 0x80,
      'truncated': Uint8List.fromList(original.sublist(0, original.length - 1)),
    };
    for (final entry in cases.entries) {
      final ciphertext = File('${directory.path}/${entry.key}.ciphertext');
      await ciphertext.writeAsBytes(entry.value, flush: true);
      final outputPath = '${directory.path}/${entry.key}.output';
      await expectLater(
        secretstream.decryptFile(
          ciphertextPath: ciphertext.path,
          plaintextPath: outputPath,
          key: encrypted.key,
          header: encrypted.header,
          expectedCiphertextSha256: encrypted.ciphertextSha256,
          expectedChunkCount: encrypted.chunkCount,
          context: context,
        ),
        throwsA(isA<AttachmentSecretstreamException>()),
      );
      expect(await File(outputPath).exists(), isFalse);
      expect(await File('$outputPath.partial').exists(), isFalse);
    }

    await expectLater(
      secretstream.decryptFile(
        ciphertextPath: encrypted.ciphertextPath,
        plaintextPath: '${directory.path}/wrong-context.output',
        key: encrypted.key,
        header: encrypted.header,
        expectedCiphertextSha256: encrypted.ciphertextSha256,
        expectedChunkCount: encrypted.chunkCount,
        context: const AttachmentEncryptionContext(
          serverId: 'server-test',
          channelId: '43',
          eventId: 'AAAAAAAAAAAAAAAAAAAAAA',
          attachmentId: 'eatt_BBBBBBBBBBBBBBBBBBBBBB',
        ),
      ),
      throwsA(isA<AttachmentSecretstreamException>()),
    );
    expect(
      await File('${directory.path}/wrong-context.output').exists(),
      isFalse,
    );
  });
}
