import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../models/link_preview_model.dart';
import '../../models/member_model.dart';
import '../../models/message_model.dart';
import '../../shared/avatar_image.dart';

final RegExp _messageUrlRegex = RegExp(
  r'((?:https?:\/\/|www\.)[^\s<>()]+)',
  caseSensitive: false,
);

class MessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final List<Member> members;
  final ScrollController? controller;
  final Future<LinkPreview?> Function(String url)? previewLoader;

  const MessageList({
    super.key,
    required this.messages,
    this.members = const [],
    this.controller,
    this.previewLoader,
  });

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
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      itemBuilder: (context, index) {
        final message = messages[index];
        return _MessageTile(
          message: message,
          member: _resolveMemberForMessage(message),
          previewLoader: previewLoader,
        );
      },
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemCount: messages.length,
    );
  }

  Member? _resolveMemberForMessage(ChatMessage message) {
    for (final member in members) {
      if (message.authorId.isNotEmpty && member.id == message.authorId) {
        return member;
      }
    }

    final author = message.author.trim().toLowerCase();
    if (author.isEmpty) {
      return null;
    }

    for (final member in members) {
      if (member.username.trim().toLowerCase() == author) {
        return member;
      }
    }

    return null;
  }
}

class _MessageTile extends StatefulWidget {
  final ChatMessage message;
  final Member? member;
  final Future<LinkPreview?> Function(String url)? previewLoader;

  const _MessageTile({
    required this.message,
    required this.member,
    required this.previewLoader,
  });

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final member = widget.member;
    final time = _formatTime(message.sentAt);
    final resolvedName = (member?.name.trim().isNotEmpty ?? false)
        ? member!.name.trim()
        : message.author;
    final fallbackInitial = resolvedName.isNotEmpty
        ? resolvedName.characters.first.toUpperCase()
        : '?';
    final detectedLinks = _extractUrls(message.content);

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
              color: NewChatColors.panelAlt,
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: _MessageAvatar(
              source: member?.avatarUrl,
              fallbackInitial: fallbackInitial,
              animate: true,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        resolvedName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
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
                  _LinkifiedMessageText(text: message.content),
                ],
                if (detectedLinks.isNotEmpty && widget.previewLoader != null) ...[
                  const SizedBox(height: 10),
                  ...detectedLinks.take(2).map(
                    (link) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _LinkPreviewCard(
                        url: link.url,
                        loadPreview: widget.previewLoader!,
                      ),
                    ),
                  ),
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

class _DetectedUrl {
  final String url;

  const _DetectedUrl({required this.url});
}

List<_DetectedUrl> _extractUrls(String text) {
  final seen = <String>{};
  final detected = <_DetectedUrl>[];

  for (final match in _messageUrlRegex.allMatches(text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) {
      continue;
    }

    final trimmed = _trimTrailingUrlPunctuation(raw);
    final normalized = _normalizeLaunchUrl(trimmed);
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }

    detected.add(_DetectedUrl(url: normalized));
  }

  return detected;
}

String _trimTrailingUrlPunctuation(String value) {
  var result = value.trim();
  const trailing = '.,!?;:]})';
  while (result.isNotEmpty && trailing.contains(result[result.length - 1])) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

String _normalizeLaunchUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  if (trimmed.toLowerCase().startsWith('http://') ||
      trimmed.toLowerCase().startsWith('https://')) {
    return trimmed;
  }

  if (trimmed.toLowerCase().startsWith('www.')) {
    return 'https://$trimmed';
  }

  return '';
}

Future<void> _launchExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _LinkifiedMessageText extends StatefulWidget {
  final String text;

  const _LinkifiedMessageText({required this.text});

  @override
  State<_LinkifiedMessageText> createState() => _LinkifiedMessageTextState();
}

class _LinkifiedMessageTextState extends State<_LinkifiedMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _messageUrlRegex.allMatches(widget.text)) {
      final start = match.start;
      var end = match.end;
      final raw = match.group(0);
      if (raw == null || raw.isEmpty) {
        continue;
      }

      final trimmed = _trimTrailingUrlPunctuation(raw);
      end = start + trimmed.length;
      final normalized = _normalizeLaunchUrl(trimmed);
      if (start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, start)));
      }

      if (normalized.isEmpty) {
        spans.add(TextSpan(text: widget.text.substring(start, end)));
      } else {
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            _launchExternalUrl(normalized);
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: widget.text.substring(start, end),
            style: TextStyle(
              color: Colors.lightBlueAccent.shade100,
              decoration: TextDecoration.underline,
              decorationColor: Colors.lightBlueAccent.shade100,
            ),
            recognizer: recognizer,
          ),
        );
      }

      if (match.end > end) {
        spans.add(TextSpan(text: widget.text.substring(end, match.end)));
      }

      cursor = match.end;
    }

    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.35),
        children: spans,
      ),
    );
  }
}

class _LinkPreviewCard extends StatefulWidget {
  final String url;
  final Future<LinkPreview?> Function(String url) loadPreview;

  const _LinkPreviewCard({
    required this.url,
    required this.loadPreview,
  });

  @override
  State<_LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<_LinkPreviewCard> {
  late Future<LinkPreview?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loadPreview(widget.url);
  }

  @override
  void didUpdateWidget(covariant _LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.loadPreview != widget.loadPreview) {
      _future = widget.loadPreview(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreview?>(
      future: _future,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done && preview == null) {
          return const SizedBox.shrink();
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: InkWell(
              onTap: () {
                _launchExternalUrl(preview?.launchUrl ?? widget.url);
              },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: BoxDecoration(
                  color: NewChatColors.panelAlt,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: NewChatColors.outline),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFB10F28),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            bottomLeft: Radius.circular(16),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: snapshot.connectionState != ConnectionState.done
                              ? _LinkPreviewLoading(url: widget.url)
                              : _LinkPreviewLoaded(preview: preview!, fallbackUrl: widget.url),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LinkPreviewLoading extends StatelessWidget {
  final String url;

  const _LinkPreviewLoading({required this.url});

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(url)?.host ?? url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          host,
          style: TextStyle(
            color: NewChatColors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          height: 16,
          width: 220,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 12,
          width: 180,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ],
    );
  }
}

class _LinkPreviewLoaded extends StatelessWidget {
  final LinkPreview preview;
  final String fallbackUrl;

  const _LinkPreviewLoaded({
    required this.preview,
    required this.fallbackUrl,
  });

  @override
  Widget build(BuildContext context) {
    final title = preview.title.trim().isNotEmpty ? preview.title.trim() : preview.launchUrl;
    final description = preview.description.trim();
    final siteName = preview.siteName.trim().isNotEmpty
        ? preview.siteName.trim()
        : (preview.hostname.trim().isNotEmpty ? preview.hostname.trim() : fallbackUrl);
    final imageUrl = preview.imageUrl.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          siteName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: NewChatColors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.lightBlueAccent.shade100,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              height: 1.3,
            ),
          ),
        ],
        if (imageUrl.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: NewChatColors.surface,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.public,
                          color: NewChatColors.textMuted,
                        ),
                      );
                    },
                  ),
                ),
                if (preview.isVideo)
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, size: 34),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MessageAvatar extends StatelessWidget {
  final String? source;
  final String fallbackInitial;
  final bool animate;

  const _MessageAvatar({
    required this.source,
    required this.fallbackInitial,
    required this.animate,
  });

  @override
  Widget build(BuildContext context) {
    return AvatarImage(
      source: source,
      fallbackInitial: fallbackInitial,
      size: 42,
      animate: animate,
    );
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