import '../models/message_model.dart';
import 'mls_delivery_models.dart';
import 'mls_event_store.dart';
import 'mls_key_package_service.dart';

class MlsMessageProjection {
  static List<ChatMessage> project({
    required String serverId,
    required List<MlsApplicationEvent> events,
    required List<VerifiedMlsDeviceBinding> directory,
  }) {
    final messages = <String, ChatMessage>{};
    for (final event in events) {
      final sender = _sender(event, directory);
      switch (event.kind) {
        case EncryptedApplicationEventKind.message:
          messages[event.eventId] = ChatMessage(
            id: event.eventId,
            channelId: event.channelId,
            author: sender.username,
            authorId: sender.userId,
            authorRole: sender.isServerOwner ? 'owner' : 'member',
            content: event.body['content'] as String,
            sentAt: event.createdAt,
            updatedAt: null,
          );
        case EncryptedApplicationEventKind.attachment:
          final attachments = (event.body['attachments'] as List)
              .map(
                (raw) => _attachment(
                  serverId: serverId,
                  event: event,
                  json: Map<String, dynamic>.from(raw as Map),
                ),
              )
              .toList(growable: false);
          messages[event.eventId] = ChatMessage(
            id: event.eventId,
            channelId: event.channelId,
            author: sender.username,
            authorId: sender.userId,
            authorRole: sender.isServerOwner ? 'owner' : 'member',
            content: event.body['content'] as String? ?? '',
            sentAt: event.createdAt,
            updatedAt: null,
            attachments: attachments,
          );
        case EncryptedApplicationEventKind.edit:
          final target = messages[event.targetEventId];
          if (target == null) {
            throw const FormatException(
              'Encrypted edit target is unavailable.',
            );
          }
          messages[event.targetEventId!] = target.copyWith(
            content: event.body['content'] as String,
            updatedAt: event.createdAt,
          );
        case EncryptedApplicationEventKind.delete:
          if (messages.remove(event.targetEventId) == null) {
            throw const FormatException(
              'Encrypted delete target is unavailable.',
            );
          }
        case EncryptedApplicationEventKind.reaction:
          final target = messages[event.targetEventId];
          if (target == null) {
            throw const FormatException(
              'Encrypted reaction target is unavailable.',
            );
          }
          final emoji = event.body['emoji'] as String;
          final remove = event.body['remove'] as bool;
          final reactions = {
            for (final reaction in target.reactions)
              reaction.emoji: reaction.userIds.toSet(),
          };
          final users = reactions.putIfAbsent(emoji, () => <String>{});
          if (remove) {
            users.remove(sender.userId);
            if (users.isEmpty) reactions.remove(emoji);
          } else {
            users.add(sender.userId);
          }
          messages[event.targetEventId!] = target.copyWith(
            reactions: reactions.entries
                .map(
                  (entry) => ChatReaction(
                    emoji: entry.key,
                    userIds: entry.value.toList(growable: false),
                  ),
                )
                .toList(growable: false),
          );
      }
    }
    return List.unmodifiable(messages.values);
  }

  static VerifiedMlsDeviceBinding _sender(
    MlsApplicationEvent event,
    List<VerifiedMlsDeviceBinding> directory,
  ) {
    final matches = directory
        .where(
          (binding) =>
              _sameBytes(binding.credential, event.senderCredential) &&
              _sameBytes(
                binding.signaturePublicKey,
                event.senderSignaturePublicKey,
              ),
        )
        .toList(growable: false);
    if (matches.length != 1 ||
        matches.single.userId.isEmpty ||
        matches.single.username.isEmpty) {
      throw const FormatException(
        'Encrypted message sender is not renderable.',
      );
    }
    return matches.single;
  }

  static ChatAttachment _attachment({
    required String serverId,
    required MlsApplicationEvent event,
    required Map<String, dynamic> json,
  }) {
    final mimeType = json['mimeType'] as String;
    final kind = mimeType.startsWith('image/')
        ? 'image'
        : mimeType.startsWith('video/')
        ? 'video'
        : mimeType.startsWith('audio/')
        ? 'audio'
        : 'file';
    return ChatAttachment(
      id: json['id'] as String,
      serverId: serverId,
      channelId: event.channelId,
      messageId: event.eventId,
      kind: kind,
      name: json['name'] as String,
      originalName: json['name'] as String,
      storedName: '',
      mimeType: mimeType,
      sizeBytes: json['sizeBytes'] as int,
      // Ciphertext is fetched and decrypted only through the channel runtime;
      // never manufacture a server URL that bypasses authenticated metadata.
      url: '',
      relativePath: '',
      createdAt: event.createdAt,
      expiresAt: null,
      deletedAt: null,
    );
  }
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
