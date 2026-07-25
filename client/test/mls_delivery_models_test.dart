import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/mls_delivery_models.dart';

String encoded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Map<String, dynamic> applicationDelivery({
  int sequence = 1,
  String channelId = '42',
  String? eventId,
  String? wireMessage,
  String operationId = 'mlsop_DDDDDDDDDDDDDDDDDDDDDD',
}) {
  return {
    'id': 'mls_AAAAAAAAAAAAAAAAAAAAAA',
    'clientOperationId': operationId,
    'channelId': channelId,
    'serverSequence': sequence,
    'messageClass': 'application',
    'acceptedEpoch': 0,
    'parentEpoch': null,
    'uploaderUserId': '7',
    'uploaderDeviceId': 'device_BBBBBBBBBBBBBBBBBBBBBBBB',
    'recipientDeviceId': null,
    'wireMessage': wireMessage ?? encoded(Uint8List.fromList([1, 2, 3])),
    'createdAt': '2026-07-24T00:00:00.000Z',
    'event': {
      'eventId': eventId ?? 'CCCCCCCCCCCCCCCCCCCCCC',
      'kind': 'message',
      'targetEventId': null,
      'encryptedAttachmentIds': const [],
    },
  };
}

void main() {
  test('claimed KeyPackages verify their server-computed wire hash', () {
    final keyPackage = Uint8List.fromList(
      List<int>.generate(96, (index) => index),
    );
    final json = {
      'id': 'kp_AAAAAAAAAAAAAAAAAAAAAA',
      'deviceId': 'device_BBBBBBBBBBBBBBBBBBBBBBBB',
      'ciphersuite': 1,
      'signaturePublicKey': encoded(Uint8List(32)),
      'identityBindingSignature': encoded(Uint8List(64)),
      'username': 'mishka',
      'yuid': 'yuid-test',
      'yuidPublicKey': encoded(Uint8List(32)),
      'keyPackage': encoded(keyPackage),
      'keyPackageHash': sha256.convert(keyPackage).toString(),
      'expiresAt': '2026-07-25T00:00:00.000Z',
    };
    expect(ClaimedMlsKeyPackage.fromJson(json).keyPackage, keyPackage);

    expect(
      () => ClaimedMlsKeyPackage.fromJson({
        ...json,
        'keyPackageHash':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      }),
      throwsFormatException,
    );
  });

  test('delivery parsing rejects wrong routing and non-increasing order', () {
    final valid = MlsDeliveryMessage.fromJson(applicationDelivery());
    expect(valid.messageClass, MlsDeliveryMessageClass.application);
    expect(valid.event?.kind, EncryptedApplicationEventKind.message);

    expect(
      () => MlsDeliveryMessage.fromJson({
        ...applicationDelivery(),
        'recipientDeviceId': 'device_DDDDDDDDDDDDDDDDDDDDDDDD',
      }),
      throwsFormatException,
    );
    expect(
      () => MlsDeliveryBatch.fromJson({
        'group': {
          'groupId': 'yappa-text-v1|server-test|42',
          'currentEpoch': 0,
          'nextSequence': 3,
        },
        'messages': [
          applicationDelivery(sequence: 2),
          applicationDelivery(sequence: 1, eventId: 'DDDDDDDDDDDDDDDDDDDDDD'),
        ],
        'deliveredSequence': 1,
      }, after: 0),
      throwsFormatException,
    );
  });

  test('API pins submitted MLS wire data and event routing', () async {
    final wire = Uint8List.fromList(List<int>.generate(80, (index) => index));
    const event = EncryptedApplicationEventRouting(
      eventId: 'CCCCCCCCCCCCCCCCCCCCCC',
      kind: EncryptedApplicationEventKind.message,
    );
    ApiClient clientReturning(Map<String, dynamic> delivery) => ApiClient(
      clientFactory: (_) => MockClient(
        (_) async => http.Response(
          jsonEncode({'ok': true, 'message': delivery}),
          201,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final validDelivery = applicationDelivery(wireMessage: encoded(wire));
    final accepted = await clientReturning(validDelivery)
        .submitMlsDeliveryMessage(
          baseUrl: 'http://127.0.0.1:4100',
          token: 'session-token',
          channelId: '42',
          clientOperationId: 'mlsop_DDDDDDDDDDDDDDDDDDDDDD',
          messageClass: MlsDeliveryMessageClass.application,
          acceptedEpoch: 0,
          wireMessage: wire,
          event: event,
        );
    expect(accepted.serverSequence, 1);

    await expectLater(
      clientReturning({
        ...validDelivery,
        'wireMessage': encoded(Uint8List.fromList([9, 9, 9])),
      }).submitMlsDeliveryMessage(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '42',
        clientOperationId: 'mlsop_DDDDDDDDDDDDDDDDDDDDDD',
        messageClass: MlsDeliveryMessageClass.application,
        acceptedEpoch: 0,
        wireMessage: wire,
        event: event,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_mls_response',
        ),
      ),
    );
  });
}
