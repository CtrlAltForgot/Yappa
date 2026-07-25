import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/attachment_secretstream.dart';

void main() {
  late Directory directory;
  late File ciphertext;
  final header = Uint8List.fromList(List<int>.generate(24, (index) => index));
  const attachmentId = 'eatt_BBBBBBBBBBBBBBBBBBBBBB';
  const digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yappa-encrypted-upload-test-',
    );
    ciphertext = File('${directory.path}/ciphertext.bin');
    await ciphertext.writeAsBytes(List<int>.generate(34, (index) => index));
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'uploads ciphertext through the configured transport and pins metadata',
    () async {
      late http.Request captured;
      final api = ApiClient(
        clientFactory: (_) => MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'ok': true,
              'attachment': {
                'id': attachmentId,
                'channelId': '42',
                'secretstreamHeader': base64Url
                    .encode(header)
                    .replaceAll('=', ''),
                'ciphertextSizeBytes': 34,
                'ciphertextSha256': digest,
                'chunkCount': 2,
                'createdAt': '2026-07-24T00:00:00.000Z',
                'expiresAt': null,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final receipt = await api.uploadEncryptedAttachment(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '42',
        attachmentId: attachmentId,
        encrypted: EncryptedAttachmentObject(
          ciphertextPath: ciphertext.path,
          key: Uint8List(32),
          header: header,
          ciphertextSha256: digest,
          ciphertextSizeBytes: 34,
          chunkCount: 2,
          plaintextSizeBytes: 0,
        ),
      );

      expect(captured.url.path, '/api/channels/42/encrypted-attachments');
      expect(captured.headers['authorization'], 'Bearer session-token');
      final multipartBody = utf8.decode(
        captured.bodyBytes,
        allowMalformed: true,
      );
      expect(multipartBody, contains('name="attachmentId"'));
      expect(multipartBody, contains(attachmentId));
      expect(multipartBody, contains('filename="ciphertext.bin"'));
      expect(receipt.id, attachmentId);
      expect(receipt.secretstreamHeader, header);
    },
  );

  test('rejects server metadata substitution after upload', () async {
    final api = ApiClient(
      clientFactory: (_) => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': true,
            'attachment': {
              'id': 'eatt_CCCCCCCCCCCCCCCCCCCCCC',
              'channelId': '42',
              'secretstreamHeader': base64Url
                  .encode(header)
                  .replaceAll('=', ''),
              'ciphertextSizeBytes': 34,
              'ciphertextSha256': digest,
              'chunkCount': 2,
              'createdAt': '2026-07-24T00:00:00.000Z',
              'expiresAt': null,
            },
          }),
          201,
        ),
      ),
    );

    await expectLater(
      api.uploadEncryptedAttachment(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '42',
        attachmentId: attachmentId,
        encrypted: EncryptedAttachmentObject(
          ciphertextPath: ciphertext.path,
          key: Uint8List(32),
          header: header,
          ciphertextSha256: digest,
          ciphertextSizeBytes: 34,
          chunkCount: 2,
          plaintextSizeBytes: 0,
        ),
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'encrypted_attachment_metadata_mismatch',
        ),
      ),
    );
  });

  test('downloads only ciphertext matching authenticated metadata', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(131, (index) => index % 127),
    );
    final actualDigest = sha256.convert(bytes).toString();
    final encodedHeader = base64Url.encode(header).replaceAll('=', '');
    final api = ApiClient(
      clientFactory: (_) => MockClient(
        (_) async => http.Response.bytes(
          bytes,
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'x-yappa-secretstream-header': encodedHeader,
            'x-yappa-ciphertext-sha256': actualDigest,
            'x-yappa-ciphertext-size': bytes.length.toString(),
            'x-yappa-chunk-count': '2',
          },
        ),
      ),
    );
    final outputPath = '${directory.path}/downloaded.bin';
    await api.downloadEncryptedAttachment(
      baseUrl: 'http://127.0.0.1:4100',
      token: 'session-token',
      channelId: '42',
      attachmentId: attachmentId,
      outputPath: outputPath,
      expectedSecretstreamHeader: header,
      expectedCiphertextSha256: actualDigest,
      expectedCiphertextSizeBytes: bytes.length,
      expectedChunkCount: 2,
    );
    expect(await File(outputPath).readAsBytes(), bytes);

    final rejectedPath = '${directory.path}/rejected.bin';
    await expectLater(
      api.downloadEncryptedAttachment(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'session-token',
        channelId: '42',
        attachmentId: attachmentId,
        outputPath: rejectedPath,
        expectedSecretstreamHeader: header,
        expectedCiphertextSha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        expectedCiphertextSizeBytes: bytes.length,
        expectedChunkCount: 2,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'encrypted_attachment_metadata_mismatch',
        ),
      ),
    );
    expect(await File(rejectedPath).exists(), isFalse);
    expect(await File('$rejectedPath.partial').exists(), isFalse);
  });
}
