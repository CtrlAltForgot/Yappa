import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/api_client.dart';

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

void main() {
  test('verifies a fresh proof and rejects a changed server key', () async {
    const serverId = 'node_identity_test';
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyText = _base64UrlNoPadding(publicKey.bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    server.listen((request) async {
      final nonce = request.uri.queryParameters['nonce'] ?? '';
      final signature = await algorithm.sign(
        utf8.encode('yappa-server-proof-v1|$serverId|$nonce'),
        keyPair: keyPair,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ok': true,
          'identity': {
            'serverId': serverId,
            'algorithm': 'Ed25519',
            'publicKey': publicKeyText,
            'nonce': nonce,
            'signature': _base64UrlNoPadding(signature.bytes),
          },
        }),
      );
      await request.response.close();
    });

    try {
      final api = ApiClient();
      final baseUrl = 'http://127.0.0.1:${server.port}';
      final verified = await api.verifyServerIdentity(
        baseUrl: baseUrl,
        expectedServerId: serverId,
      );
      expect(verified.serverId, serverId);
      expect(verified.publicKey, publicKeyText);

      await expectLater(
        api.verifyServerIdentity(
          baseUrl: baseUrl,
          expectedServerId: serverId,
          expectedPublicKey: _base64UrlNoPadding(List<int>.filled(32, 7)),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'server_identity_changed',
          ),
        ),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('accepts only a signed identity-bound LAN discovery route', () async {
    const serverId = 'node_lan_discovery_test';
    const advertisedAddress = '203.0.113.10';
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyText = _base64UrlNoPadding(publicKey.bytes);
    final httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    httpServer.listen((request) async {
      final nonce = request.uri.queryParameters['nonce'] ?? '';
      final signature = await algorithm.sign(
        utf8.encode('yappa-server-proof-v1|$serverId|$nonce'),
        keyPair: keyPair,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ok': true,
          'identity': {
            'serverId': serverId,
            'algorithm': 'Ed25519',
            'publicKey': publicKeyText,
            'nonce': nonce,
            'signature': _base64UrlNoPadding(signature.bytes),
          },
        }),
      );
      await request.response.close();
    });
    final discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      41200,
      reuseAddress: true,
    );
    discoverySocket.listen((event) async {
      if (event != RawSocketEvent.read) return;
      final datagram = discoverySocket.receive();
      if (datagram == null) return;
      final request = jsonDecode(utf8.decode(datagram.data)) as Map;
      final nonce = request['nonce']?.toString() ?? '';
      final proof =
          'yappa-lan-discovery-v1|$serverId|$nonce|'
          '${httpServer.port}|$advertisedAddress';
      final signature = await algorithm.sign(
        utf8.encode(proof),
        keyPair: keyPair,
      );
      discoverySocket.send(
        utf8.encode(
          jsonEncode({
            'protocol': 'yappa-lan-discovery-v1',
            'serverId': serverId,
            'algorithm': 'Ed25519',
            'publicKey': publicKeyText,
            'nonce': nonce,
            'tlsPort': httpServer.port,
            'advertisedAddress': advertisedAddress,
            'signature': _base64UrlNoPadding(signature.bytes),
          }),
        ),
        datagram.address,
        datagram.port,
      );
    });

    try {
      final route = await ApiClient().discoverLanServer(
        expectedServerId: serverId,
        expectedPublicKey: publicKeyText,
        expectedAdvertisedAddress: advertisedAddress,
        discoveryAddress: InternetAddress.loopbackIPv4,
      );
      expect(route, isNotNull);
      expect(route!.serverId, serverId);
      expect(route.publicKey, publicKeyText);
      expect(route.tlsPort, httpServer.port);
      expect(route.advertisedAddress, advertisedAddress);
      expect(InternetAddress.tryParse(route.host)?.isLoopback, isTrue);

      final rejected = await ApiClient().discoverLanServer(
        expectedServerId: serverId,
        expectedPublicKey: publicKeyText,
        expectedAdvertisedAddress: '198.51.100.20',
        timeout: const Duration(milliseconds: 250),
        discoveryAddress: InternetAddress.loopbackIPv4,
      );
      expect(rejected, isNull);
    } finally {
      discoverySocket.close();
      await httpServer.close(force: true);
    }
  });
}
