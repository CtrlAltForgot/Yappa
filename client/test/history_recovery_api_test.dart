import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yappa/data/api_client.dart';

const _transferId = 'recovery_abcdefghijklmnopqrstuv';
const _sourceDeviceId = 'device_abcdefghijklmnopqrstuvwx';
const _destinationDeviceId = 'device_zyxwvutsrqponmlkjihgfedc';
const _channelId = '7';
const _signature =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    'abcdefghijklmnopqrstuvwx';

Map<String, dynamic> _transferJson({
  required Uint8List manifest,
  required String manifestHash,
  String state = 'uploading',
  int uploadedChunks = 0,
  int uploadedBytes = 0,
  bool includeManifest = true,
}) => {
  'id': _transferId,
  'channelId': _channelId,
  'sourceDeviceId': _sourceDeviceId,
  'destinationDeviceId': _destinationDeviceId,
  'firstServerSequence': 10,
  'lastServerSequence': 11,
  'eventCount': 2,
  'chunkCount': 2,
  'totalBytes': 6,
  if (includeManifest)
    'manifest': base64Url.encode(manifest).replaceAll('=', ''),
  'manifestSha256': manifestHash,
  'yuidSignature': _signature,
  'state': state,
  'uploadedChunks': uploadedChunks,
  'uploadedBytes': uploadedBytes,
  'createdAt': '2026-07-28T12:00:00.000Z',
  'readyAt': state == 'ready' || state == 'consumed'
      ? '2026-07-28T12:01:00.000Z'
      : null,
  'consumedAt': state == 'consumed' ? '2026-07-28T12:02:00.000Z' : null,
  'canceledAt': null,
  'expiresAt': '2026-08-27T12:01:00.000Z',
};

void main() {
  test(
    'pins the complete recovery transfer upload/download lifecycle',
    () async {
      final manifest = Uint8List.fromList(utf8.encode('{"version":1}'));
      final manifestHash = sha256.convert(manifest).toString();
      final chunks = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ];
      final chunkHashes = chunks.map(
        (chunk) => sha256.convert(chunk).toString(),
      );
      var uploads = 0;

      final api = ApiClient(
        clientFactory: (_) => MockClient.streaming((request, bodyStream) async {
          final path = request.url.path;
          final body = await bodyStream.toBytes();
          Map<String, dynamic> response;
          var status = 200;
          if (request.method == 'POST' &&
              path == '/api/channels/7/mls/history-recovery/transfers') {
            final submitted =
                jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
            expect(submitted['id'], _transferId);
            expect(submitted['destinationDeviceId'], _destinationDeviceId);
            expect(submitted['eventCount'], 2);
            expect(submitted['manifestSha256'], manifestHash);
            response = {
              'created': true,
              'transfer': _transferJson(
                manifest: manifest,
                manifestHash: manifestHash,
              ),
            };
            status = 201;
          } else if (request.method == 'PUT' && path.contains('/chunks/')) {
            final index = int.parse(path.split('/').last);
            expect(request.headers['content-type'], 'application/octet-stream');
            expect(body, chunks[index]);
            expect(
              request.headers['x-yappa-content-sha256'],
              chunkHashes.elementAt(index),
            );
            uploads += 1;
            response = {
              'created': true,
              'transferId': _transferId,
              'chunkIndex': index,
              'sizeBytes': body.length,
              'ciphertextSha256': chunkHashes.elementAt(index),
            };
            status = 201;
          } else if (request.method == 'POST' && path.endsWith('/finalize')) {
            response = {
              'finalized': true,
              'transfer': _transferJson(
                manifest: manifest,
                manifestHash: manifestHash,
                state: 'ready',
                uploadedChunks: 2,
                uploadedBytes: 6,
              ),
            };
          } else if (request.method == 'GET' &&
              path == '/api/channels/7/mls/history-recovery/transfers') {
            response = {
              'transfers': [
                _transferJson(
                  manifest: manifest,
                  manifestHash: manifestHash,
                  state: 'ready',
                  uploadedChunks: 2,
                  uploadedBytes: 6,
                ),
              ],
            };
          } else if (request.method == 'GET' && path.contains('/chunks/')) {
            final index = int.parse(path.split('/').last);
            response = {
              'transferId': _transferId,
              'chunkIndex': index,
              'ciphertext': base64Url.encode(chunks[index]).replaceAll('=', ''),
              'ciphertextSha256': chunkHashes.elementAt(index),
              'sizeBytes': chunks[index].length,
            };
          } else if (request.method == 'POST' && path.endsWith('/consume')) {
            response = {
              'consumed': true,
              'transfer': _transferJson(
                manifest: manifest,
                manifestHash: manifestHash,
                state: 'consumed',
                uploadedChunks: 2,
                uploadedBytes: 6,
                includeManifest: false,
              ),
            };
          } else if (request.method == 'DELETE') {
            response = {'canceled': true, 'transferId': _transferId};
          } else {
            return http.StreamedResponse(
              Stream.value(utf8.encode('not found')),
              404,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(response))),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final created = await api.createHistoryRecoveryTransfer(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        channelId: _channelId,
        transferId: _transferId,
        sourceDeviceId: _sourceDeviceId,
        destinationDeviceId: _destinationDeviceId,
        firstServerSequence: 10,
        lastServerSequence: 11,
        chunkCount: 2,
        totalBytes: 6,
        manifest: manifest,
        manifestSha256: manifestHash,
        yuidSignature: _signature,
      );
      expect(created.changed, isTrue);

      for (var index = 0; index < chunks.length; index++) {
        expect(
          await api.uploadHistoryRecoveryChunk(
            baseUrl: 'http://127.0.0.1:4100',
            token: 'token',
            transferId: _transferId,
            chunkIndex: index,
            ciphertext: chunks[index],
            ciphertextSha256: chunkHashes.elementAt(index),
          ),
          isTrue,
        );
      }
      expect(uploads, 2);
      final finalized = await api.finalizeHistoryRecoveryTransfer(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        transferId: _transferId,
      );
      expect(finalized.transfer.state, HistoryRecoveryTransferState.ready);

      final available = await api.fetchHistoryRecoveryTransfers(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        channelId: _channelId,
        destinationDeviceId: _destinationDeviceId,
      );
      expect(available, hasLength(1));
      for (var index = 0; index < chunks.length; index++) {
        final downloaded = await api.downloadHistoryRecoveryChunk(
          baseUrl: 'http://127.0.0.1:4100',
          token: 'token',
          transferId: _transferId,
          chunkIndex: index,
          expectedSha256: chunkHashes.elementAt(index),
          expectedSizeBytes: chunks[index].length,
        );
        expect(downloaded.ciphertext, chunks[index]);
      }
      final consumed = await api.consumeHistoryRecoveryTransfer(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        transferId: _transferId,
      );
      expect(consumed.transfer.state, HistoryRecoveryTransferState.consumed);
      expect(
        await api.cancelHistoryRecoveryTransfer(
          baseUrl: 'http://127.0.0.1:4100',
          token: 'token',
          transferId: _transferId,
        ),
        isTrue,
      );
    },
  );

  test('rejects a substituted destination in the ready list', () async {
    final manifest = Uint8List.fromList([1]);
    final manifestHash = sha256.convert(manifest).toString();
    final api = ApiClient(
      clientFactory: (_) => MockClient((_) async {
        final transfer = _transferJson(
          manifest: manifest,
          manifestHash: manifestHash,
          state: 'ready',
          uploadedChunks: 2,
          uploadedBytes: 6,
        )..['destinationDeviceId'] = _sourceDeviceId;
        return http.Response(
          jsonEncode({
            'transfers': [transfer],
          }),
          200,
        );
      }),
    );
    await expectLater(
      api.fetchHistoryRecoveryTransfers(
        baseUrl: 'http://127.0.0.1:4100',
        token: 'token',
        channelId: _channelId,
        destinationDeviceId: _destinationDeviceId,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'invalid_history_recovery_response',
        ),
      ),
    );
  });
}
