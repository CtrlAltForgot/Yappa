import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'image_adjust_dialog.dart';

class PickedAdjustedImage {
  final Uint8List bytes;
  final String extension;
  final String mimeType;

  const PickedAdjustedImage({
    required this.bytes,
    required this.extension,
    required this.mimeType,
  });
}

Future<PickedAdjustedImage?> pickAndAdjustImage({
  required BuildContext context,
  required double aspectRatio,
  required String title,
  int maxOutputDimension = 512,
  List<String> allowedExtensions = const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
    withData: true,
  );

  final picked = result?.files.single;
  if (picked == null) {
    return null;
  }

  final bytes = picked.bytes ??
      (picked.path != null ? await File(picked.path!).readAsBytes() : null);
  if (bytes == null || bytes.isEmpty) {
    return null;
  }

  if (!context.mounted) {
    return null;
  }

  final extension = (picked.extension ?? 'png').trim().toLowerCase();
  final adjusted = await showImageAdjustDialog(
    context: context,
    sourceBytes: bytes,
    aspectRatio: aspectRatio,
    originalExtension: extension,
    maxOutputDimension: maxOutputDimension,
    title: title,
  );

  if (adjusted == null) {
    return null;
  }

  return PickedAdjustedImage(
    bytes: adjusted.bytes,
    extension: adjusted.extension,
    mimeType: adjusted.mimeType,
  );
}