import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/attachment_secretstream.dart';
import 'package:yappa/data/encrypted_attachment_failure.dart';

void main() {
  test('attachment failures never expose local paths or crypto details', () {
    final fileMessage = encryptedAttachmentFailureMessage(
      const FileSystemException(
        'Permission denied',
        '/home/mishka/private/passwords.txt',
      ),
      operation: EncryptedAttachmentOperation.save,
    );
    expect(fileMessage, contains('selected save location'));
    expect(fileMessage, isNot(contains('/home/mishka')));
    expect(fileMessage, isNot(contains('passwords.txt')));

    final integrityMessage = encryptedAttachmentFailureMessage(
      const AttachmentSecretstreamException(
        'Secretstream final tag mismatch at chunk 42.',
      ),
      operation: EncryptedAttachmentOperation.preview,
    );
    expect(integrityMessage, contains('could not authenticate'));
    expect(integrityMessage, contains('not opened or saved'));
    expect(integrityMessage, isNot(contains('chunk 42')));
  });

  test('attachment transport failures remain actionable and bounded', () {
    expect(
      encryptedAttachmentFailureMessage(
        ApiException('raw server detail', statusCode: 429),
        operation: EncryptedAttachmentOperation.send,
      ),
      contains('temporarily limited'),
    );
    expect(
      encryptedAttachmentFailureMessage(
        ApiException('raw server detail', statusCode: 401),
        operation: EncryptedAttachmentOperation.save,
      ),
      contains('no longer authorized'),
    );
  });
}
