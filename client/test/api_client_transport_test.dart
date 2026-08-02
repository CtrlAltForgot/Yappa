import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/models/server_model.dart';

void main() {
  group('ApiClient transport normalization', () {
    final api = ApiClient();

    test('allows HTTP for loopback and private LAN hosts', () {
      expect(api.normalizeBaseUrl('127.0.0.1'), 'http://127.0.0.1:4100');
      expect(
        api.normalizeBaseUrl('192.168.1.254'),
        'http://192.168.1.254:4100',
      );
      expect(api.normalizeBaseUrl('server.local'), 'http://server.local:4100');
      expect(api.normalizeBaseUrl('yappa-node'), 'http://yappa-node:4100');
      expect(api.normalizeBaseUrl('[::1]'), 'http://[::1]:4100');
    });

    test('defaults public hosts to HTTPS and its standard port', () {
      expect(
        api.normalizeBaseUrl('chat.example.com'),
        'https://chat.example.com',
      );
      expect(
        api.normalizeBaseUrl('https://chat.example.com:4443'),
        'https://chat.example.com:4443',
      );
      expect(api.normalizeBaseUrl('172.32.0.1'), 'https://172.32.0.1');
      expect(
        api.normalizeBaseUrl('https://203.0.113.10:8443'),
        'https://203.0.113.10:8443',
      );
    });

    test('upgrades a retired LAN backend route from signed discovery', () {
      expect(
        api.secureBaseUrlForDiscoveredRoute(
          savedBaseUrl: 'http://192.168.1.254:4100',
          advertisedAddress: '70.112.26.136',
        ),
        'https://70.112.26.136',
      );
      expect(
        () => api.secureBaseUrlForDiscoveredRoute(
          savedBaseUrl: 'http://192.168.1.254:4100',
          advertisedAddress: '192.168.1.254',
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'invalid_lan_route',
          ),
        ),
      );
    });

    test('rejects explicit insecure public transport', () {
      expect(
        () => api.normalizeBaseUrl('http://chat.example.com'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', 'insecure_transport')
              .having(
                (error) => error.message,
                'message',
                contains('must use HTTPS'),
              ),
        ),
      );
    });

    test('rejects paths, credentials, queries, and unsupported schemes', () {
      for (final input in [
        'https://chat.example.com/api',
        'https://user@chat.example.com',
        'https://chat.example.com?token=value',
        'ftp://chat.example.com',
      ]) {
        expect(
          () => api.normalizeBaseUrl(input),
          throwsA(isA<ApiException>()),
          reason: input,
        );
      }
    });
  });

  test('server cards show their configured direct address', () {
    const custom = ChatServer(
      id: 'server-2',
      name: 'Yappa',
      shortName: 'Y',
      tagline: '',
      description: '',
      address: 'https://chat.example.com',
    );

    expect(custom.joinAddress, 'https://chat.example.com');
  });

  test('network assets use the API client transport', () async {
    late Uri requestedUri;
    final api = ApiClient(
      clientFactory: (_) => MockClient((request) async {
        requestedUri = request.url;
        return http.Response.bytes(<int>[1, 2, 3, 4], 200);
      }),
    );

    final bytes = await api.downloadNetworkAsset(
      'https://203.0.113.10/api/attachments/7?grant=signed',
    );

    expect(requestedUri.host, '203.0.113.10');
    expect(requestedUri.queryParameters['grant'], 'signed');
    expect(bytes, <int>[1, 2, 3, 4]);
  });
}
