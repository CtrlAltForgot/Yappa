import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/features/chat/message_list.dart';
import 'package:yappa/models/channel_model.dart';
import 'package:yappa/models/message_model.dart';

void main() {
  testWidgets('encrypted attachment renders without a network preview', (
    tester,
  ) async {
    ChatAttachment? requested;
    final attachment = ChatAttachment(
      id: 'eatt_${'a' * 22}',
      serverId: 'server',
      channelId: _channel.id,
      messageId: 'evt_${'b' * 22}',
      kind: 'image',
      name: 'private.png',
      originalName: 'private.png',
      storedName: '',
      mimeType: 'image/png',
      sizeBytes: 2048,
      url: '',
      relativePath: '',
      createdAt: DateTime.utc(2026),
      expiresAt: null,
      deletedAt: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageList(
            messages: [
              ChatMessage(
                id: attachment.messageId!,
                channelId: _channel.id,
                author: 'mishka',
                authorId: '1',
                authorRole: 'owner',
                content: '',
                sentAt: DateTime.utc(2026),
                updatedAt: null,
                attachments: [attachment],
              ),
            ],
            onDownloadEncryptedAttachment: (value) async {
              requested = value;
            },
            onPreviewEncryptedAttachment: (value, outputPath) async {},
          ),
        ),
      ),
    );

    expect(find.text('private.png'), findsOneWidget);
    expect(find.textContaining('End-to-end encrypted'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip('Decrypt local preview'), findsOneWidget);

    await tester.tap(find.byTooltip('Decrypt and save'));
    await tester.pumpAndSettle();
    expect(requested, same(attachment));
  });

  testWidgets('encrypted attachment failure hides local filesystem details', (
    tester,
  ) async {
    final attachment = ChatAttachment(
      id: 'eatt_${'d' * 22}',
      serverId: 'server',
      channelId: _channel.id,
      messageId: 'evt_${'e' * 22}',
      kind: 'file',
      name: 'private.txt',
      originalName: 'private.txt',
      storedName: '',
      mimeType: 'text/plain',
      sizeBytes: 64,
      url: '',
      relativePath: '',
      createdAt: DateTime.utc(2026),
      expiresAt: null,
      deletedAt: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageList(
            messages: [
              ChatMessage(
                id: attachment.messageId!,
                channelId: _channel.id,
                author: 'mishka',
                authorId: '1',
                authorRole: 'owner',
                content: '',
                sentAt: DateTime.utc(2026),
                updatedAt: null,
                attachments: [attachment],
              ),
            ],
            onDownloadEncryptedAttachment: (_) async {
              throw const FileSystemException(
                'Permission denied',
                '/home/mishka/secret/export.txt',
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Decrypt and save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected save location'), findsOneWidget);
    expect(find.textContaining('/home/mishka'), findsNothing);
    expect(find.textContaining('export.txt'), findsNothing);
  });

  testWidgets(
    'authenticated reaction chips toggle through the encrypted path',
    (tester) async {
      String? toggled;
      final message = ChatMessage(
        id: 'evt_${'c' * 22}',
        channelId: _channel.id,
        author: 'mishka',
        authorId: '1',
        authorRole: 'owner',
        content: 'hello',
        sentAt: DateTime.utc(2026),
        updatedAt: null,
        reactions: const [
          ChatReaction(emoji: '👍', userIds: ['1', '2']),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageList(
              messages: [message],
              currentUserId: '1',
              onToggleReaction: (target, emoji) async {
                expect(target, same(message));
                toggled = emoji;
              },
            ),
          ),
        ),
      );

      expect(find.text('👍 2'), findsOneWidget);
      await tester.tap(find.text('👍 2'));
      await tester.pump();
      expect(toggled, '👍');
    },
  );
}

const _channel = ChatChannel(
  id: 'channel_abcdefghijklmnopqrstuv',
  serverId: 'server',
  name: 'secure',
  type: ChannelType.text,
  encryptionMode: ChannelEncryptionMode.e2ee,
  encryptionVersion: 1,
);
