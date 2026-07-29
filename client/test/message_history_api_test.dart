import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yappa/data/api_client.dart';

void main() {
  test(
    'parses a bounded history page and forwards its opaque cursor',
    () async {
      late http.Request captured;
      final api = ApiClient(
        clientFactory: (_) => MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'ok': true,
              'messages': [
                {
                  'id': '41',
                  'channelId': '7',
                  'content': 'older durable message',
                  'createdAt': '2026-07-28T12:00:00.000Z',
                  'author': {'id': '3', 'username': 'Mira', 'role': 'member'},
                  'attachments': [],
                  'reactions': [],
                },
              ],
              'page': {
                'direction': 'before',
                'hasMore': true,
                'nextCursor': 'opaque_payload.opaque_signature',
                'forwardCursor': 'forward_payload.forward_signature',
                'backwardCursor': 'backward_payload.backward_signature',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final page = await api.fetchMessages(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '7',
        cursor: 'previous_payload.previous_signature',
        limit: 25,
      );

      expect(captured.url.path, '/api/channels/7/messages');
      expect(captured.url.queryParameters, {
        'limit': '25',
        'cursor': 'previous_payload.previous_signature',
      });
      expect(captured.headers['authorization'], 'Bearer session-token');
      expect(page.messages.single.id, '41');
      expect(page.messages.single.author, 'Mira');
      expect(page.direction, 'before');
      expect(page.hasMore, true);
      expect(page.nextCursor, 'opaque_payload.opaque_signature');
      expect(page.forwardCursor, 'forward_payload.forward_signature');
      expect(page.backwardCursor, 'backward_payload.backward_signature');
    },
  );

  test('rejects contradictory history cursor metadata', () async {
    final api = ApiClient(
      clientFactory: (_) => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': true,
            'messages': [],
            'page': {
              'direction': 'before',
              'hasMore': true,
              'nextCursor': null,
              'forwardCursor': null,
              'backwardCursor': null,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      api.fetchMessages(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '7',
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_history_response',
        ),
      ),
    );
  });

  test('creates a pinned cursor for an exact message boundary', () async {
    late http.Request captured;
    final api = ApiClient(
      clientFactory: (_) => MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'ok': true,
            'cursor': 'anchor_payload.anchor_signature',
            'direction': 'after',
            'messageId': '41',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final cursor = await api.createMessageHistoryCursor(
      baseUrl: 'http://127.0.0.1:4100',
      token: 'session-token',
      channelId: '7',
      messageId: '41',
      direction: 'after',
    );

    expect(captured.url.path, '/api/channels/7/messages/cursor');
    expect(captured.url.queryParameters, {
      'messageId': '41',
      'direction': 'after',
    });
    expect(captured.headers['authorization'], 'Bearer session-token');
    expect(cursor, 'anchor_payload.anchor_signature');
  });
}
