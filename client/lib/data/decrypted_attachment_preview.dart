import 'dart:io';

import '../models/message_model.dart';

class DecryptedAttachmentPreview {
  final Directory directory;
  final File file;
  bool _disposed = false;

  DecryptedAttachmentPreview._({required this.directory, required this.file});

  static Future<DecryptedAttachmentPreview> create(
    ChatAttachment attachment,
  ) async {
    if (!attachment.isImage || attachment.url.isNotEmpty) {
      throw const FormatException(
        'Only encrypted images can use a local preview.',
      );
    }
    final directory = await Directory.systemTemp.createTemp(
      'yappa-decrypted-preview-',
    );
    try {
      await _chmod(directory.path, '700');
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'preview.${_extensionFor(attachment.mimeType)}',
      );
      return DecryptedAttachmentPreview._(directory: directory, file: file);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> protect() async {
    if (_disposed || !await file.exists()) {
      throw const FileSystemException(
        'The decrypted preview file is unavailable.',
      );
    }
    try {
      await _chmod(file.path, '600');
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  static String _extensionFor(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'png',
    };
  }

  static Future<void> _chmod(String path, String mode) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw const FileSystemException(
        'Could not protect the decrypted preview.',
      );
    }
  }
}
