import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/mls_key_package_service.dart';
import 'package:yappa/data/mls_message_projection.dart';

void main() {
  test(
    'projects authenticated messages, edits, reactions, attachments, and deletes',
    () {
      final credential = Uint8List.fromList([1, 2, 3]);
      final signatureKey = Uint8List.fromList(List<int>.filled(32, 4));
      final binding = VerifiedMlsDeviceBinding(
        yuid: 'yuid',
        deviceId: 'device_${'d' * 24}',
        userId: '7',
        username: 'alice',
        credential: credential,
        signaturePublicKey: signatureKey,
        isServerOwner: true,
      );
      MlsApplicationEvent event({
        required int sequence,
        required String id,
        required EncryptedApplicationEventKind kind,
        required Map<String, dynamic> body,
        String? target,
      }) => MlsApplicationEvent(
        serverSequence: sequence,
        epoch: 1,
        eventId: id,
        channelId: '1',
        kind: kind,
        targetEventId: target,
        createdAt: DateTime.utc(2026, 7, 24, 12, sequence),
        body: body,
        senderCredential: credential,
        senderSignaturePublicKey: signatureKey,
      );
      final messageId = 'evt_${'m' * 22}';
      final attachmentEventId = 'evt_${'a' * 22}';
      final base = event(
        sequence: 1,
        id: messageId,
        kind: EncryptedApplicationEventKind.message,
        body: {'content': 'before'},
      );
      final edit = event(
        sequence: 2,
        id: 'evt_${'e' * 22}',
        kind: EncryptedApplicationEventKind.edit,
        target: messageId,
        body: {'content': 'after'},
      );
      final attachment = event(
        sequence: 3,
        id: attachmentEventId,
        kind: EncryptedApplicationEventKind.attachment,
        body: {
          'content': 'caption protected with the file',
          'attachments': [
            {
              'id': 'eatt_${'f' * 22}',
              'name': 'photo.png',
              'mimeType': 'image/png',
              'sizeBytes': 123,
              'key': 'unused',
              'secretstreamHeader': 'unused',
              'ciphertextSha256': 'a' * 64,
              'chunkCount': 1,
            },
          ],
        },
      );
      final reaction = event(
        sequence: 4,
        id: 'evt_${'r' * 22}',
        kind: EncryptedApplicationEventKind.reaction,
        target: messageId,
        body: {'emoji': '👍', 'remove': false},
      );

      final projected = MlsMessageProjection.project(
        serverId: 'server-id',
        events: [base, edit, attachment, reaction],
        directory: [binding],
      );
      expect(projected, hasLength(2));
      expect(projected.first.content, 'after');
      expect(projected.first.authorId, '7');
      expect(projected.first.authorRole, 'owner');
      expect(projected.first.updatedAt, edit.createdAt);
      expect(projected.first.reactions.single.emoji, '👍');
      expect(projected.first.reactions.single.userIds, ['7']);
      expect(projected.last.attachments.single.name, 'photo.png');
      expect(projected.last.attachments.single.url, isEmpty);
      expect(projected.last.content, 'caption protected with the file');

      final deleted = MlsMessageProjection.project(
        serverId: 'server-id',
        events: [
          base,
          edit,
          attachment,
          event(
            sequence: 5,
            id: 'evt_${'x' * 22}',
            kind: EncryptedApplicationEventKind.delete,
            target: messageId,
            body: const {},
          ),
        ],
        directory: [binding],
      );
      expect(deleted.map((message) => message.id), [attachmentEventId]);
      final removedReaction = MlsMessageProjection.project(
        serverId: 'server-id',
        events: [
          base,
          reaction,
          event(
            sequence: 5,
            id: 'evt_${'q' * 22}',
            kind: EncryptedApplicationEventKind.reaction,
            target: messageId,
            body: {'emoji': '👍', 'remove': true},
          ),
        ],
        directory: [binding],
      );
      expect(removedReaction.single.reactions, isEmpty);
    },
  );
}
