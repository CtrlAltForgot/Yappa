import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'attachment_secretstream.dart';
import 'mls_delivery_models.dart';
import 'mls_event_store.dart';
import 'mls_native.dart';
import 'mls_send_coordinator.dart';

typedef MlsAttachmentDirectoryProvider = Future<Directory> Function();

class MlsAttachmentInput {
  final String plaintextPath;
  final String name;
  final String mimeType;

  const MlsAttachmentInput({
    required this.plaintextPath,
    required this.name,
    required this.mimeType,
  });
}

class MlsAttachmentCoordinator {
  final ApiClient api;
  final MlsSendCoordinator sender;
  final AttachmentSecretstream secretstream;
  final String baseUrl;
  final String token;
  final String serverId;
  final String channelId;
  final MlsAttachmentDirectoryProvider supportDirectory;
  final Random _random;

  MlsAttachmentCoordinator({
    required this.api,
    required this.sender,
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.channelId,
    AttachmentSecretstream? secretstream,
    this.supportDirectory = getApplicationSupportDirectory,
    Random? random,
  }) : secretstream = secretstream ?? AttachmentSecretstream(),
       _random = random ?? Random.secure();

  Future<MlsDeliveryMessage> sendFile({
    required String plaintextPath,
    required String name,
    required String mimeType,
    String content = '',
  }) => sendFiles(
    files: [
      MlsAttachmentInput(
        plaintextPath: plaintextPath,
        name: name,
        mimeType: mimeType,
      ),
    ],
    content: content,
  );

  Future<MlsDeliveryMessage> sendFiles({
    required List<MlsAttachmentInput> files,
    String content = '',
  }) async {
    if (files.isEmpty || files.length > 10 || content.length > 4000) {
      throw const FormatException('Invalid encrypted attachment event.');
    }
    for (final file in files) {
      _validateDisplayMetadata(file.name, file.mimeType);
    }
    final eventId = _randomId();
    final staged = <({EncryptedAttachmentObject encrypted, String id})>[];
    late final MlsOutgoingApplication outgoing;
    try {
      for (final file in files) {
        final attachmentId = 'eatt_${_randomId()}';
        final ciphertextPath = await _ciphertextPath(attachmentId);
        final encrypted = await secretstream.encryptFile(
          plaintextPath: file.plaintextPath,
          ciphertextPath: ciphertextPath,
          context: AttachmentEncryptionContext(
            serverId: serverId,
            channelId: channelId,
            eventId: eventId,
            attachmentId: attachmentId,
          ),
        );
        await _restrictCiphertext(File(ciphertextPath));
        staged.add((encrypted: encrypted, id: attachmentId));
      }
      outgoing = await sender.stage(
        kind: EncryptedApplicationEventKind.attachment,
        eventId: eventId,
        body: {
          'content': content,
          'attachments': [
            for (var index = 0; index < staged.length; index += 1)
              {
                'id': staged[index].id,
                'name': files[index].name,
                'mimeType': files[index].mimeType,
                'sizeBytes': staged[index].encrypted.plaintextSizeBytes,
                'key': _encode(staged[index].encrypted.key),
                'secretstreamHeader': _encode(staged[index].encrypted.header),
                'ciphertextSha256': staged[index].encrypted.ciphertextSha256,
                'chunkCount': staged[index].encrypted.chunkCount,
              },
          ],
        },
      );
    } catch (_) {
      for (final item in staged) {
        item.encrypted.key.fillRange(0, item.encrypted.key.length, 0);
        final ciphertext = File(item.encrypted.ciphertextPath);
        if (await ciphertext.exists()) await ciphertext.delete();
      }
      rethrow;
    }
    for (final item in staged) {
      item.encrypted.key.fillRange(0, item.encrypted.key.length, 0);
    }
    return _uploadAndSubmit(outgoing);
  }

  Future<List<MlsDeliveryMessage>> resumePending() async {
    final pending = await sender.localDevice.read(
      (native) => native.pendingOutgoingApplications(),
    );
    final delivered = <MlsDeliveryMessage>[];
    for (final outgoing in pending) {
      final routing = MlsApplicationEvent.routingFromPlaintext(
        plaintext: outgoing.plaintext,
        channelId: channelId,
      );
      if (routing.kind != EncryptedApplicationEventKind.attachment) {
        continue;
      }
      delivered.add(await _uploadAndSubmit(outgoing));
    }
    return delivered;
  }

  Future<void> downloadFile({
    required MlsApplicationEvent event,
    required String attachmentId,
    required String plaintextPath,
  }) async {
    if (event.channelId != channelId ||
        event.kind != EncryptedApplicationEventKind.attachment) {
      throw const FormatException('Invalid encrypted attachment event.');
    }
    final attachments = (event.body['attachments'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .where((item) => item['id'] == attachmentId)
        .toList(growable: false);
    if (attachments.length != 1) {
      throw const FormatException('Encrypted attachment was not found.');
    }
    final attachment = attachments.single;
    final ciphertextPath = await _downloadPath(attachmentId);
    final ciphertext = File(ciphertextPath);
    final key = _decode(attachment['key'].toString());
    final header = _decode(attachment['secretstreamHeader'].toString());
    final chunkCount = attachment['chunkCount'] as int;
    final plaintextSize = attachment['sizeBytes'] as int;
    try {
      await api.downloadEncryptedAttachment(
        baseUrl: baseUrl,
        token: token,
        channelId: channelId,
        attachmentId: attachmentId,
        outputPath: ciphertextPath,
        expectedSecretstreamHeader: header,
        expectedCiphertextSha256: attachment['ciphertextSha256'].toString(),
        expectedCiphertextSizeBytes: plaintextSize + (chunkCount * 17),
        expectedChunkCount: chunkCount,
      );
      await _restrictCiphertext(ciphertext);
      await secretstream.decryptFile(
        ciphertextPath: ciphertextPath,
        plaintextPath: plaintextPath,
        key: key,
        header: header,
        expectedCiphertextSha256: attachment['ciphertextSha256'].toString(),
        expectedChunkCount: chunkCount,
        context: AttachmentEncryptionContext(
          serverId: serverId,
          channelId: channelId,
          eventId: event.eventId,
          attachmentId: attachmentId,
        ),
      );
    } finally {
      key.fillRange(0, key.length, 0);
      header.fillRange(0, header.length, 0);
      if (await ciphertext.exists()) await ciphertext.delete();
      final partial = File('$ciphertextPath.partial');
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<MlsDeliveryMessage> _uploadAndSubmit(
    MlsOutgoingApplication outgoing,
  ) async {
    final json = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(outgoing.plaintext)) as Map,
    );
    final body = Map<String, dynamic>.from(json['body'] as Map);
    final attachments = (body['attachments'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    final ciphertextFiles = <File>[];
    final keys = <Uint8List>[];
    final headers = <Uint8List>[];
    try {
      for (final attachment in attachments) {
        final attachmentId = attachment['id'].toString();
        final ciphertext = File(await _ciphertextPath(attachmentId));
        ciphertextFiles.add(ciphertext);
        if (!await ciphertext.exists()) {
          throw const FileSystemException(
            'Pending encrypted attachment ciphertext is missing.',
          );
        }
        final key = _decode(attachment['key'].toString());
        final header = _decode(attachment['secretstreamHeader'].toString());
        keys.add(key);
        headers.add(header);
        await api.uploadEncryptedAttachment(
          baseUrl: baseUrl,
          token: token,
          channelId: channelId,
          attachmentId: attachmentId,
          encrypted: EncryptedAttachmentObject(
            ciphertextPath: ciphertext.path,
            key: key,
            header: header,
            ciphertextSha256: attachment['ciphertextSha256'].toString(),
            ciphertextSizeBytes: await ciphertext.length(),
            chunkCount: attachment['chunkCount'] as int,
            plaintextSizeBytes: attachment['sizeBytes'] as int,
          ),
        );
      }
      final delivery = await sender.submitPendingOperation(
        outgoing.operationId,
      );
      for (final ciphertext in ciphertextFiles) {
        if (await ciphertext.exists()) await ciphertext.delete();
      }
      return delivery;
    } finally {
      for (final key in keys) {
        key.fillRange(0, key.length, 0);
      }
      for (final header in headers) {
        // Header is public but clear the reconstructed buffer consistently.
        header.fillRange(0, header.length, 0);
      }
      final isPending = await sender.localDevice.read(
        (native) => native.pendingOutgoingApplications().any(
          (item) => item.operationId == outgoing.operationId,
        ),
      );
      if (!isPending) {
        for (final ciphertext in ciphertextFiles) {
          if (await ciphertext.exists()) await ciphertext.delete();
        }
      }
    }
  }

  Future<String> _ciphertextPath(String attachmentId) async {
    return _protectedPath('mls-attachment-outbox', attachmentId);
  }

  Future<String> _downloadPath(String attachmentId) async {
    return _protectedPath('mls-attachment-downloads', attachmentId);
  }

  Future<String> _protectedPath(
    String directoryName,
    String attachmentId,
  ) async {
    if (!RegExp(r'^eatt_[A-Za-z0-9_-]{22}$').hasMatch(attachmentId)) {
      throw const FormatException('Invalid encrypted attachment id.');
    }
    final directory = Directory(
      '${(await supportDirectory()).path}${Platform.pathSeparator}'
      '$directoryName',
    );
    await directory.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const FileSystemException(
          'Could not protect the attachment outbox.',
        );
      }
    }
    return '${directory.path}${Platform.pathSeparator}$attachmentId.bin';
  }

  Future<void> _restrictCiphertext(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        if (await file.exists()) await file.delete();
        throw const FileSystemException(
          'Could not protect encrypted attachment staging.',
        );
      }
    }
  }

  void _validateDisplayMetadata(String name, String mimeType) {
    if (name.isEmpty ||
        name.length > 255 ||
        name.contains('/') ||
        name.contains(r'\') ||
        mimeType.isEmpty ||
        mimeType.length > 128) {
      throw const FormatException('Invalid encrypted attachment metadata.');
    }
  }

  String _randomId() => base64Url
      .encode(
        List<int>.generate(16, (_) => _random.nextInt(256), growable: false),
      )
      .replaceAll('=', '');

  static String _encode(List<int> value) =>
      base64Url.encode(value).replaceAll('=', '');

  static Uint8List _decode(String value) => Uint8List.fromList(
    base64Url.decode(
      value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
    ),
  );
}
