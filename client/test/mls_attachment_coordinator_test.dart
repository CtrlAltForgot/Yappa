import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yappa/data/api_client.dart';
import 'package:yappa/data/attachment_secretstream.dart';
import 'package:yappa/data/mls_attachment_coordinator.dart';
import 'package:yappa/data/mls_delivery_models.dart';
import 'package:yappa/data/mls_event_store.dart';
import 'package:yappa/data/mls_local_state.dart';
import 'package:yappa/data/mls_send_coordinator.dart';
import 'package:yappa/data/secret_storage.dart';

class _MemorySecrets implements SecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _AttachmentApi extends ApiClient {
  bool loseFirstUpload = true;
  int uploadAttempts = 0;
  final Map<String, Uint8List> uploadedCiphertext = {};

  @override
  Future<EncryptedAttachmentUploadReceipt> uploadEncryptedAttachment({
    required String baseUrl,
    required String token,
    required String channelId,
    required String attachmentId,
    required EncryptedAttachmentObject encrypted,
  }) async {
    uploadAttempts += 1;
    uploadedCiphertext[attachmentId] = await File(
      encrypted.ciphertextPath,
    ).readAsBytes();
    if (loseFirstUpload) {
      loseFirstUpload = false;
      throw ApiException('Connection lost after attachment acceptance.');
    }
    return EncryptedAttachmentUploadReceipt(
      id: attachmentId,
      channelId: channelId,
      secretstreamHeader: Uint8List.fromList(encrypted.header),
      ciphertextSizeBytes: encrypted.ciphertextSizeBytes,
      ciphertextSha256: encrypted.ciphertextSha256,
      chunkCount: encrypted.chunkCount,
      createdAt: DateTime.utc(2026),
      expiresAt: null,
    );
  }

  @override
  Future<void> downloadEncryptedAttachment({
    required String baseUrl,
    required String token,
    required String channelId,
    required String attachmentId,
    required String outputPath,
    required Uint8List expectedSecretstreamHeader,
    required String expectedCiphertextSha256,
    required int expectedCiphertextSizeBytes,
    required int expectedChunkCount,
  }) async {
    final ciphertext = uploadedCiphertext[attachmentId]!;
    expect(ciphertext, hasLength(expectedCiphertextSizeBytes));
    await File(outputPath).writeAsBytes(ciphertext, flush: true);
  }

  @override
  Future<MlsDeliveryMessage> submitMlsDeliveryMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String clientOperationId,
    required MlsDeliveryMessageClass messageClass,
    required int acceptedEpoch,
    required Uint8List wireMessage,
    int? parentEpoch,
    String? recipientDeviceId,
    EncryptedApplicationEventRouting? event,
  }) async => MlsDeliveryMessage(
    id: 'mls_${'m' * 22}',
    clientOperationId: clientOperationId,
    channelId: channelId,
    serverSequence: 1,
    messageClass: messageClass,
    acceptedEpoch: acceptedEpoch,
    parentEpoch: parentEpoch,
    uploaderUserId: '1',
    uploaderDeviceId: 'device_${'u' * 24}',
    recipientDeviceId: recipientDeviceId,
    wireMessage: wireMessage,
    createdAt: DateTime.utc(2026),
    event: event,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supportsNative = Platform.isLinux || Platform.isWindows;

  test(
    'attachment upload and MLS binding resume after lost response',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'yappa-mls-attachment-',
      );
      final secrets = _MemorySecrets();
      addTearDown(() => root.delete(recursive: true));
      final plaintext = File('${root.path}/plain.txt');
      await plaintext.writeAsString('encrypted attachment content');
      final secondPlaintext = File('${root.path}/second.txt');
      await secondPlaintext.writeAsString('second encrypted file');
      final local = await MlsLocalDevice.open(
        serverId: 'server-id',
        secretStorage: secrets,
        supportDirectory: () async => Directory('${root.path}/state'),
      );
      addTearDown(local.close);
      await local.mutate(
        (native) => native.createGroup(
          Uint8List.fromList('yappa-text-v1|server-id|1'.codeUnits),
        ),
      );
      final eventStore = await MlsEventStore.open(
        serverId: 'server-id',
        deviceId: local.deviceId,
        channelId: '1',
        secretStorage: secrets,
        supportDirectory: () async => Directory('${root.path}/events'),
      );
      addTearDown(eventStore.close);
      final api = _AttachmentApi();
      final sender = MlsSendCoordinator(
        api: api,
        localDevice: local,
        eventStore: eventStore,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
        senderIsOwner: true,
      );
      final attachments = MlsAttachmentCoordinator(
        api: api,
        sender: sender,
        baseUrl: 'http://127.0.0.1:4100',
        token: 'unused',
        serverId: 'server-id',
        channelId: '1',
        supportDirectory: () async => Directory('${root.path}/attachments'),
      );

      await expectLater(
        attachments.sendFiles(
          files: [
            MlsAttachmentInput(
              plaintextPath: plaintext.path,
              name: 'plain.txt',
              mimeType: 'text/plain',
            ),
            MlsAttachmentInput(
              plaintextPath: secondPlaintext.path,
              name: 'second.txt',
              mimeType: 'text/plain',
            ),
          ],
          content: 'authenticated caption',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(
        await local.read((native) => native.pendingOutgoingApplications()),
        hasLength(1),
      );
      expect(
        Directory(
          '${root.path}/attachments',
        ).listSync(recursive: true).whereType<File>(),
        hasLength(2),
      );

      final delivered = await attachments.resumePending();
      expect(delivered, hasLength(1));
      expect(api.uploadAttempts, 3);
      expect(
        await local.read((native) => native.pendingOutgoingApplications()),
        isEmpty,
      );
      final event = eventStore.events.single;
      expect(event.kind, EncryptedApplicationEventKind.attachment);
      expect(event.body['content'], 'authenticated caption');
      expect(event.body['attachments'], hasLength(2));
      expect(
        Directory(
          '${root.path}/attachments',
        ).listSync(recursive: true).whereType<File>(),
        isEmpty,
      );

      final attachmentId =
          ((event.body['attachments'] as List).first as Map)['id'].toString();
      final downloaded = '${root.path}/downloaded.txt';
      await attachments.downloadFile(
        event: event,
        attachmentId: attachmentId,
        plaintextPath: downloaded,
      );
      expect(
        await File(downloaded).readAsString(),
        'encrypted attachment content',
      );
      expect(
        Directory(
          '${root.path}/attachments',
        ).listSync(recursive: true).whereType<File>(),
        isEmpty,
      );
    },
    skip: !supportsNative,
  );
}
