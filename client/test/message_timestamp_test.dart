import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/features/chat/message_list.dart';
import 'package:yappa/models/message_model.dart';

void main() {
  testWidgets('UTC message timestamps render in the desktop local timezone', (
    tester,
  ) async {
    final sentAt = DateTime.utc(2026, 7, 25, 0, 9);
    final local = sentAt.toLocal();
    final expectedHour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final expectedMinute = local.minute.toString().padLeft(2, '0');
    final expectedSuffix = local.hour >= 12 ? 'PM' : 'AM';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageList(
            messages: [
              ChatMessage(
                id: 'message-timezone',
                channelId: 'general',
                author: 'mishka',
                authorId: '1',
                authorRole: 'owner',
                content: 'timezone check',
                sentAt: sentAt,
                updatedAt: null,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.text('$expectedHour:$expectedMinute $expectedSuffix'),
      findsOneWidget,
    );
  });
}
