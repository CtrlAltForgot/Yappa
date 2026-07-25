import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/decrypted_attachment_preview.dart';
import 'package:yappa/models/message_model.dart';

ChatAttachment _attachment({String kind = 'image', String url = ''}) {
  return ChatAttachment(
    id: 'eatt_${'a' * 22}',
    serverId: 'server',
    channelId: '1',
    messageId: 'event',
    kind: kind,
    name: kind == 'image' ? 'private.png' : 'private.txt',
    originalName: kind == 'image' ? 'private.png' : 'private.txt',
    storedName: '',
    mimeType: kind == 'image' ? 'image/png' : 'text/plain',
    sizeBytes: 4,
    url: url,
    relativePath: '',
    createdAt: DateTime.utc(2026, 7, 24),
    expiresAt: null,
    deletedAt: null,
  );
}

void main() {
  test('decrypted preview is private and recursively erased', () async {
    final preview = await DecryptedAttachmentPreview.create(_attachment());
    addTearDown(preview.dispose);
    final directoryPath = preview.directory.path;
    await preview.file.writeAsBytes([1, 2, 3, 4], flush: true);
    await preview.protect();

    expect(await preview.file.exists(), true);
    if (Platform.isLinux) {
      final directoryMode = await Process.run('stat', [
        '-c',
        '%a',
        preview.directory.path,
      ]);
      final fileMode = await Process.run('stat', [
        '-c',
        '%a',
        preview.file.path,
      ]);
      expect(directoryMode.stdout.toString().trim(), '700');
      expect(fileMode.stdout.toString().trim(), '600');
    }

    await preview.dispose();
    expect(await Directory(directoryPath).exists(), false);
    await preview.dispose();
  });

  test('preview rejects plaintext and non-image attachments', () async {
    await expectLater(
      DecryptedAttachmentPreview.create(_attachment(kind: 'file')),
      throwsFormatException,
    );
    await expectLater(
      DecryptedAttachmentPreview.create(
        _attachment(url: 'https://example.test/plain.png'),
      ),
      throwsFormatException,
    );
  });
}
