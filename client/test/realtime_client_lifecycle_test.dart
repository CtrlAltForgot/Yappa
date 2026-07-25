import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/realtime_client.dart';
import 'package:yappa/models/server_model.dart';

void main() {
  test('accepts Dart secure WebSocket implicit port normalization', () {
    final publicUri = Uri.parse('https://70.112.26.136');
    expect(isExpectedSecureLanWebSocketPort(0, publicUri), isTrue);
    expect(isExpectedSecureLanWebSocketPort(443, publicUri), isTrue);
    expect(isExpectedSecureLanWebSocketPort(8443, publicUri), isFalse);
  });
  test(
    'reports an unavailable realtime route once while reconnecting',
    () async {
      final unavailable = Completer<void>();
      var unavailableCount = 0;
      final realtime = RealtimeClient(
        onHello: (_, _, _, _, _) {},
        onPresenceUpdate: (_, _) {},
        onMessage: (_) {},
        onMessageUpdated: (_) {},
        onMessageDeleted: (_, _) {},
        onServerUpdated: (_, _, _) {},
        onError: (_) {},
        onUnavailable: () {
          unavailableCount += 1;
          if (!unavailable.isCompleted) unavailable.complete();
        },
      );
      addTearDown(realtime.dispose);

      realtime.connect(
        server: const ChatServer(
          id: 'server-id',
          name: 'Unavailable server',
          shortName: 'US',
          tagline: '',
          description: '',
          address: 'http://127.0.0.1:1',
        ),
        token: 'unused',
      );

      await unavailable.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(unavailableCount, 1);

      realtime.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(unavailableCount, 1);
    },
  );
}
