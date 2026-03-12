import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../models/message_model.dart';

class MessageList extends StatelessWidget {
  final List<ChatMessage> messages;

  const MessageList({super.key, required this.messages});

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No messages here yet. Start the signal.',
          style: TextStyle(color: NewChatColors.textMuted),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      itemBuilder: (context, index) {
        final message = messages[index];
        return _MessageTile(message: message);
      },
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemCount: messages.length,
    );
  }
}

class _MessageTile extends StatelessWidget {
  final ChatMessage message;

  const _MessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    final time = _formatTime(message.sentAt);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                colors: [NewChatColors.accent, NewChatColors.accentGlow],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                message.author.isNotEmpty
                    ? message.author[0].toUpperCase()
                    : '?',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      message.author,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      time,
                      style: TextStyle(
                        color: NewChatColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (message.content.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(message.content),
                ],
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  ...message.attachments.map(
                    (attachment) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: attachment.isImage
                          ? _ImageAttachmentTile(attachment: attachment)
                          : _FileAttachmentTile(attachment: attachment),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime value) {
    final hour =
        value.hour > 12 ? value.hour - 12 : (value.hour == 0 ? 12 : value.hour);
    final minute = value.minute.toString().padLeft(2, '0');
    final suffix = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }
}

class _ImageAttachmentTile extends StatefulWidget {
  final ChatAttachment attachment;

  const _ImageAttachmentTile({required this.attachment});

  @override
  State<_ImageAttachmentTile> createState() => _ImageAttachmentTileState();
}

class _ImageAttachmentTileState extends State<_ImageAttachmentTile> {
  bool _hovering = false;

  Future<void> _downloadFile(BuildContext context) async {
    await _downloadAttachmentToDisk(context, widget.attachment);
  }

  void _openPreview(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close image preview',
      barrierColor: Colors.black.withValues(alpha: 0.82),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _ImagePreviewDialog(attachment: widget.attachment);
      },
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      color: NewChatColors.panel,
      items: const [
        PopupMenuItem<String>(
          value: 'download',
          child: Text('Download File'),
        ),
      ],
    );

    if (selected == 'download' && context.mounted) {
      await _downloadFile(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(context, details),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: InkWell(
          onTap: () => _openPreview(context),
          borderRadius: BorderRadius.circular(18),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 520,
                maxHeight: 360,
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(color: Colors.transparent),
                  ),
                  Positioned.fill(
                    child: Image.network(
                      widget.attachment.url,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return Center(
                          child: Text(
                            'Could not load image preview',
                            style: TextStyle(color: NewChatColors.textMuted),
                          ),
                        );
                      },
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      },
                    ),
                  ),
                  if (_hovering)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        opacity: _hovering ? 1 : 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(
                                Icons.open_in_full_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Open',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileAttachmentTile extends StatelessWidget {
  final ChatAttachment attachment;

  const _FileAttachmentTile({required this.attachment});

  bool get _isPreviewableText {
    final mime = attachment.mimeType.toLowerCase();
    final name = attachment.name.toLowerCase();

    if (mime.startsWith('text/')) return true;

    return name.endsWith('.txt') ||
        name.endsWith('.md') ||
        name.endsWith('.json') ||
        name.endsWith('.yaml') ||
        name.endsWith('.yml') ||
        name.endsWith('.log') ||
        name.endsWith('.csv') ||
        name.endsWith('.xml') ||
        name.endsWith('.ini');
  }

  Future<void> _openFileExternally() async {
    final uri = Uri.tryParse(attachment.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _downloadFile(BuildContext context) async {
    await _downloadAttachmentToDisk(context, attachment);
  }

  Future<void> _confirmOpen(BuildContext context) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: NewChatColors.panel,
          title: const Text('Open file?'),
          content: Text(
            'Yappa does not scan files for viruses or malware.\n\nOnly open or download files you trust.\n\nFile: ${attachment.name}',
            style: TextStyle(color: NewChatColors.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('download'),
              child: const Text('Download'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('open'),
              child: const Text('Open Anyway'),
            ),
          ],
        );
      },
    );

    if (action == 'open') {
      await _openFileExternally();
    } else if (action == 'download' && context.mounted) {
      await _downloadFile(context);
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      color: NewChatColors.panel,
      items: const [
        PopupMenuItem<String>(
          value: 'download',
          child: Text('Download File'),
        ),
      ],
    );

    if (selected == 'download' && context.mounted) {
      await _downloadFile(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = attachment.isVideo
        ? Icons.movie_rounded
        : attachment.isAudio
            ? Icons.audiotrack_rounded
            : Icons.insert_drive_file_rounded;

    final kindLabel = attachment.isVideo
        ? 'Video'
        : attachment.isAudio
            ? 'Audio'
            : 'File';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onSecondaryTapDown: (details) => _showContextMenu(context, details),
          child: InkWell(
            onTap: () => _confirmOpen(context),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NewChatColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: NewChatColors.outline),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: NewChatColors.accentGlow),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          attachment.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$kindLabel • ${_formatBytes(attachment.sizeBytes)}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: NewChatColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 18,
                    color: NewChatColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_isPreviewableText) ...[
          const SizedBox(height: 8),
          _TextFilePreview(attachment: attachment),
        ],
      ],
    );
  }
}

class _TextFilePreview extends StatefulWidget {
  final ChatAttachment attachment;

  const _TextFilePreview({required this.attachment});

  @override
  State<_TextFilePreview> createState() => _TextFilePreviewState();
}

class _TextFilePreviewState extends State<_TextFilePreview> {
  late Future<String> _previewFuture;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _previewFuture = _loadPreview();
  }

  Future<String> _loadPreview() async {
    final uri = Uri.tryParse(widget.attachment.url);
    if (uri == null) {
      throw Exception('Invalid preview URL.');
    }

    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not load preview.');
    }

    final text = response.body;
    if (text.isEmpty) return '(empty file)';
    return text.length > 12000 ? '${text.substring(0, 12000)}\n\n…' : text;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _previewFuture,
      builder: (context, snapshot) {
        Widget child;

        if (snapshot.connectionState != ConnectionState.done) {
          child = const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (snapshot.hasError) {
          child = Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Could not load text preview',
              style: TextStyle(color: NewChatColors.textMuted),
            ),
          );
        } else {
          child = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.data ?? '',
                maxLines: _expanded ? null : 8,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.fade,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: NewChatColors.panelAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: NewChatColors.outline),
                  ),
                  child: Text(
                    _expanded ? 'Collapse Preview' : 'Expand Preview',
                    style: TextStyle(
                      color: NewChatColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NewChatColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: NewChatColors.outline),
          ),
          child: child,
        );
      },
    );
  }
}

class _ImagePreviewDialog extends StatefulWidget {
  final ChatAttachment attachment;

  const _ImagePreviewDialog({required this.attachment});

  @override
  State<_ImagePreviewDialog> createState() => _ImagePreviewDialogState();
}

class _ImagePreviewDialogState extends State<_ImagePreviewDialog> {
  final TransformationController _controller = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleZoomAt(Offset localPosition, Size viewportSize) {
    setState(() {
      if (_zoomed) {
        _controller.value = Matrix4.identity();
        _zoomed = false;
      } else {
        const scale = 2.0;
        final dx = (viewportSize.width / 2) - (localPosition.dx * scale);
        final dy = (viewportSize.height / 2) - (localPosition.dy * scale);

        _controller.value = Matrix4.identity()
          ..translateByDouble(dx, dy, 0, 1)
          ..scaleByDouble(scale, scale, 1.0, 1.0);

        _zoomed = true;
      }
    });
  }

  Future<void> _downloadFile(BuildContext context) async {
    await _downloadAttachmentToDisk(context, widget.attachment);
  }

  Future<void> _openInSystem() async {
    final uri = Uri.tryParse(widget.attachment.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      behavior: HitTestBehavior.opaque,
      child: Material(
        color: Colors.transparent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewportSize = Size(
              constraints.maxWidth * 0.88,
              constraints.maxHeight * 0.88,
            );

            return Stack(
              children: [
                Center(
                  child: GestureDetector(
                    onTapDown: (details) =>
                        _toggleZoomAt(details.localPosition, viewportSize),
                    child: SizedBox(
                      width: viewportSize.width,
                      height: viewportSize.height,
                      child: InteractiveViewer(
                        transformationController: _controller,
                        constrained: false,
                        clipBehavior: Clip.none,
                        boundaryMargin: const EdgeInsets.all(4000),
                        minScale: 1,
                        maxScale: 6,
                        child: SizedBox(
                          width: viewportSize.width,
                          height: viewportSize.height,
                          child: Image.network(
                            widget.attachment.url,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: 500,
                                height: 260,
                                decoration: BoxDecoration(
                                  color: NewChatColors.panel,
                                  borderRadius: BorderRadius.circular(18),
                                  border:
                                      Border.all(color: NewChatColors.outline),
                                ),
                                child: Center(
                                  child: Text(
                                    'Could not load image',
                                    style: TextStyle(
                                      color: NewChatColors.textMuted,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PreviewButton(
                        icon: Icons.download_rounded,
                        tooltip: 'Download file',
                        onTap: () => _downloadFile(context),
                      ),
                      const SizedBox(width: 8),
                      _PreviewButton(
                        icon: Icons.open_in_new_rounded,
                        tooltip: 'Open in system viewer',
                        onTap: _openInSystem,
                      ),
                      const SizedBox(width: 8),
                      _PreviewButton(
                        icon: Icons.close_rounded,
                        tooltip: 'Close',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PreviewButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _PreviewButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}

Future<void> _downloadAttachmentToDisk(
  BuildContext context,
  ChatAttachment attachment,
) async {
  try {
    final uri = Uri.tryParse(attachment.url);
    if (uri == null) {
      throw Exception('Invalid file URL.');
    }

    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Download failed with status ${response.statusCode}.');
    }

    final bytes = response.bodyBytes;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save file',
      fileName: attachment.name,
      bytes: bytes,
    );

    if (path == null || path.isEmpty) {
      return;
    }

    final file = File(path);
    await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${attachment.name}')),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}