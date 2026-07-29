import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/features/chat/chat_area.dart';
import 'package:yappa/models/channel_model.dart';
import 'package:yappa/models/message_model.dart';

void main() {
  testWidgets('history window shifts preserve the retained edge message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: _HistoryHarness()));
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey<String>('message-list-scroll'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(scrollable);
    await _jumpToBoundary(tester, scrollState.position, older: true);
    final olderAnchor = _visibleEdgeMessage(tester, older: true);
    final olderAnchorBefore = tester.getBottomLeft(olderAnchor).dy;

    await tester.tap(find.text('Load older messages'));
    await tester.pumpAndSettle();
    final olderAnchorAfter = tester.getBottomLeft(olderAnchor).dy;
    expect(olderAnchorAfter, closeTo(olderAnchorBefore, 1));

    await _jumpToBoundary(tester, scrollState.position, older: false);
    final newerAnchor = _visibleEdgeMessage(tester, older: false);
    final newerAnchorBefore = tester.getBottomLeft(newerAnchor).dy;

    await tester.tap(find.text('Load newer messages'));
    await tester.pumpAndSettle();
    final newerAnchorAfter = tester.getBottomLeft(newerAnchor).dy;
    expect(newerAnchorAfter, closeTo(newerAnchorBefore, 1));
  });
}

Future<void> _jumpToBoundary(
  WidgetTester tester,
  ScrollPosition position, {
  required bool older,
}) async {
  for (var index = 0; index < 5; index += 1) {
    position.jumpTo(
      older ? position.maxScrollExtent : position.minScrollExtent,
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Finder _visibleEdgeMessage(WidgetTester tester, {required bool older}) {
  final candidates = <(Finder, double)>[];
  for (var number = 100; number < 150; number += 1) {
    final finder = find.byKey(ValueKey<String>('message-item-$number'));
    if (finder.evaluate().isNotEmpty) {
      candidates.add((finder, tester.getCenter(finder).dy));
    }
  }
  expect(candidates, isNotEmpty);
  candidates.sort((left, right) => left.$2.compareTo(right.$2));
  return older ? candidates.first.$1 : candidates.last.$1;
}

class _HistoryHarness extends StatefulWidget {
  const _HistoryHarness();

  @override
  State<_HistoryHarness> createState() => _HistoryHarnessState();
}

class _HistoryHarnessState extends State<_HistoryHarness> {
  List<ChatMessage> _messages = _page(100);
  bool _hasNewer = false;

  static List<ChatMessage> _page(int start) => List.generate(100, (index) {
    final number = start + index;
    return ChatMessage(
      id: '$number',
      channelId: 'general',
      author: 'Mira',
      authorId: '1',
      authorRole: 'owner',
      content: 'message $number',
      sentAt: DateTime.utc(2026, 7, 28, 12, number),
      updatedAt: null,
    );
  });

  Future<void> _older() async {
    setState(() {
      _messages = _page(50);
      _hasNewer = true;
    });
  }

  Future<void> _newer() async {
    setState(() {
      _messages = _page(100);
      _hasNewer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatArea(
        channel: const ChatChannel(
          id: 'general',
          serverId: 'server',
          name: 'general',
          type: ChannelType.text,
        ),
        messages: _messages,
        hasOlderMessages: true,
        hasNewerMessages: _hasNewer,
        onLoadOlderMessages: _older,
        onLoadNewerMessages: _newer,
        onSend: (_) {},
      ),
    );
  }
}
