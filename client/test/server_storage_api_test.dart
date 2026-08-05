import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yappa/data/api_client.dart';

void main() {
  test('parses owner-safe durable storage status', () async {
    late http.Request captured;
    final api = ApiClient(
      clientFactory: (_) => MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'ok': true,
            'storage': {
              'available': true,
              'status': 'warning',
              'acceptsDurableWrites': true,
              'filesystem': {
                'availableBytes': 1500,
                'availableAfterWriteBytes': 1500,
                'totalBytes': 10000,
              },
              'thresholds': {
                'warningFreeBytes': 2000,
                'criticalFreeBytes': 500,
              },
              'usage': {
                'databaseBytes': 100,
                'ordinaryAttachmentBytes': 200,
                'encryptedAttachmentBytes': 300,
                'backupBytes': null,
                'backupMonitoringEnabled': false,
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final storage = await api.fetchServerStorage(
      baseUrl: 'http://127.0.0.1:4100',
      token: 'owner-token',
    );

    expect(captured.url.path, '/api/server/storage');
    expect(captured.headers['authorization'], 'Bearer owner-token');
    expect(storage.status, 'warning');
    expect(storage.acceptsDurableWrites, true);
    expect(storage.availableBytes, 1500);
    expect(storage.databaseBytes, 100);
    expect(storage.encryptedAttachmentBytes, 300);
    expect(storage.backupMonitoringEnabled, false);
    expect(storage.backupBytes, isNull);
  });
}
