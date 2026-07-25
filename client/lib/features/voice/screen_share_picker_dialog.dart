import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app/theme.dart';

Future<DesktopCapturerSource?> showYappaScreenSharePickerDialog({
  required BuildContext context,
  required List<SourceType> types,
}) async {
  final sources = await desktopCapturer.getSources(
    types: types,
    thumbnailSize: ThumbnailSize(320, 180),
  );
  if (!context.mounted) {
    return null;
  }
  if (sources.isEmpty) {
    return null;
  }

  return showDialog<DesktopCapturerSource>(
    context: context,
    builder: (context) => _YappaScreenSharePickerDialog(sources: sources),
  );
}

class _YappaScreenSharePickerDialog extends StatelessWidget {
  final List<DesktopCapturerSource> sources;

  const _YappaScreenSharePickerDialog({required this.sources});

  String _labelFor(DesktopCapturerSource source, int index) {
    final trimmed = source.name.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }

    return source.type == SourceType.Window
        ? 'Window ${index + 1}'
        : 'Screen ${index + 1}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: NewChatColors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: 760,
        height: 620,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose what to share',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Select a display or application window. Sharing starts only after you choose one.',
                style: TextStyle(fontSize: 13, color: NewChatColors.textMuted),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: GridView.builder(
                  itemCount: sources.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 340,
                    mainAxisExtent: 238,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final label = _labelFor(source, index);
                    return Material(
                      color: NewChatColors.surface.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.of(context).pop(source),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Container(
                                  width: double.infinity,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: NewChatColors.outline,
                                    ),
                                  ),
                                  child:
                                      source.thumbnail == null ||
                                          source.thumbnail!.isEmpty
                                      ? Icon(
                                          source.type == SourceType.Window
                                              ? Icons.crop_square_rounded
                                              : Icons.desktop_windows_rounded,
                                          color: Colors.white70,
                                          size: 38,
                                        )
                                      : Image.memory(
                                          source.thumbnail!,
                                          fit: BoxFit.contain,
                                          gaplessPlayback: true,
                                          errorBuilder:
                                              (_, error, stackTrace) => Icon(
                                                source.type == SourceType.Window
                                                    ? Icons.crop_square_rounded
                                                    : Icons
                                                          .desktop_windows_rounded,
                                                color: Colors.white70,
                                                size: 38,
                                              ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                source.type == SourceType.Window
                                    ? 'Application window'
                                    : 'Entire display',
                                style: TextStyle(
                                  color: NewChatColors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
