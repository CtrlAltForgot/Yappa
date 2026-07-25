import 'dart:async';
import 'dart:io';

import 'api_client.dart';
import 'attachment_secretstream.dart';
import 'mls_native.dart';

enum EncryptedAttachmentOperation { send, save, preview }

class EncryptedAttachmentOperationException implements Exception {
  final String message;

  const EncryptedAttachmentOperationException(this.message);

  @override
  String toString() => message;
}

String encryptedAttachmentFailureMessage(
  Object error, {
  required EncryptedAttachmentOperation operation,
}) {
  if (error is EncryptedAttachmentOperationException) {
    return error.message;
  }

  if (error is ApiException) {
    return switch (error.statusCode) {
      401 || 403 =>
        'Your session is no longer authorized for encrypted attachments. '
            'Reconnect and try again.',
      413 => 'The server rejected this attachment because it is too large.',
      429 =>
        'Encrypted attachment requests are temporarily limited. '
            'Wait a moment and retry.',
      _ =>
        'The encrypted attachment could not be transferred. '
            'Check the connection and retry.',
    };
  }

  if (error is SocketException || error is TimeoutException) {
    return 'The encrypted attachment could not be transferred. '
        'Check the connection and retry.';
  }

  if (error is FileSystemException) {
    return switch (operation) {
      EncryptedAttachmentOperation.send =>
        'Yappa could not read or safely stage the selected file. '
            'Check its permissions and available disk space.',
      EncryptedAttachmentOperation.save =>
        'Yappa could not write the selected save location. '
            'Check its permissions and available disk space.',
      EncryptedAttachmentOperation.preview =>
        'Yappa could not create the protected local preview. '
            'Check available disk space and retry.',
    };
  }

  if (error is AttachmentSecretstreamException ||
      error is FormatException ||
      error is MlsNativeException) {
    return switch (operation) {
      EncryptedAttachmentOperation.send =>
        'Yappa could not securely prepare these files. '
            'Reconnect the encrypted feed and retry.',
      EncryptedAttachmentOperation.save ||
      EncryptedAttachmentOperation.preview =>
        'Yappa could not authenticate this encrypted attachment. '
            'It was not opened or saved.',
    };
  }

  return switch (operation) {
    EncryptedAttachmentOperation.send =>
      'Yappa could not send these encrypted files. Retry the operation.',
    EncryptedAttachmentOperation.save =>
      'Yappa could not decrypt and save this attachment. Retry the operation.',
    EncryptedAttachmentOperation.preview =>
      'Yappa could not decrypt this preview. Retry the operation.',
  };
}
