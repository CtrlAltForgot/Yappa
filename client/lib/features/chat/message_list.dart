import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';

import '../../app/theme.dart';
import '../../data/decrypted_attachment_preview.dart';
import '../../data/encrypted_attachment_failure.dart';
import '../../models/link_preview_model.dart';
import '../../models/member_model.dart';
import '../../models/message_model.dart';
import '../../shared/avatar_image.dart';

final RegExp _messageUrlRegex = RegExp(
  r'((?:https?:\/\/|www\.)[^\s<>()]+)',
  caseSensitive: false,
);

String _formatAttachmentBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KB';
  return '${(kib / 1024).toStringAsFixed(1)} MB';
}

enum _MessageAction { edit, delete }

class MessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final List<Member> members;
  final ScrollController? controller;
  final Future<LinkPreview?> Function(String url)? previewLoader;
  final String? currentUserId;
  final bool canDeleteAnyMessage;
  final ValueChanged<ChatMessage>? onEditMessage;
  final ValueChanged<ChatMessage>? onDeleteMessage;
  final Future<void> Function(ChatAttachment attachment)?
  onDownloadEncryptedAttachment;
  final Future<void> Function(ChatAttachment attachment, String outputPath)?
  onPreviewEncryptedAttachment;
  final Future<void> Function(ChatMessage message, String emoji)?
  onToggleReaction;

  const MessageList({
    super.key,
    required this.messages,
    this.members = const [],
    this.controller,
    this.previewLoader,
    this.currentUserId,
    this.canDeleteAnyMessage = false,
    this.onEditMessage,
    this.onDeleteMessage,
    this.onDownloadEncryptedAttachment,
    this.onPreviewEncryptedAttachment,
    this.onToggleReaction,
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

    return ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 10),
      itemBuilder: (context, index) {
        final sourceIndex = messages.length - 1 - index;
        final message = messages[sourceIndex];
        final previous = sourceIndex == 0 ? null : messages[sourceIndex - 1];
        final startsDay =
            previous == null || !_isSameDay(previous.sentAt, message.sentAt);
        final showHeader =
            previous == null ||
            startsDay ||
            !_isSameAuthor(previous, message) ||
            message.sentAt.difference(previous.sentAt).abs() >
                const Duration(minutes: 7);

        return Column(
          key: ValueKey<String>('message-${message.id}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (startsDay) _MessageDayDivider(date: message.sentAt),
            _MessageTile(
              message: message,
              member: _resolveMemberForMessage(message),
              showHeader: showHeader,
              previewLoader: previewLoader,
              currentUserId: currentUserId,
              canDeleteAnyMessage: canDeleteAnyMessage,
              onEditMessage: onEditMessage,
              onDeleteMessage: onDeleteMessage,
              onDownloadEncryptedAttachment: onDownloadEncryptedAttachment,
              onPreviewEncryptedAttachment: onPreviewEncryptedAttachment,
              onToggleReaction: onToggleReaction,
            ),
          ],
        );
      },
      itemCount: messages.length,
    );
  }

  bool _isSameAuthor(ChatMessage first, ChatMessage second) {
    if (first.authorId.isNotEmpty && second.authorId.isNotEmpty) {
      return first.authorId == second.authorId;
    }
    return first.author.trim().toLowerCase() ==
        second.author.trim().toLowerCase();
  }

  bool _isSameDay(DateTime first, DateTime second) {
    final firstLocal = first.toLocal();
    final secondLocal = second.toLocal();
    return firstLocal.year == secondLocal.year &&
        firstLocal.month == secondLocal.month &&
        firstLocal.day == secondLocal.day;
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
  final bool showHeader;
  final Future<LinkPreview?> Function(String url)? previewLoader;
  final String? currentUserId;
  final bool canDeleteAnyMessage;
  final ValueChanged<ChatMessage>? onEditMessage;
  final ValueChanged<ChatMessage>? onDeleteMessage;
  final Future<void> Function(ChatAttachment attachment)?
  onDownloadEncryptedAttachment;
  final Future<void> Function(ChatAttachment attachment, String outputPath)?
  onPreviewEncryptedAttachment;
  final Future<void> Function(ChatMessage message, String emoji)?
  onToggleReaction;

  const _MessageTile({
    required this.message,
    required this.member,
    required this.showHeader,
    required this.previewLoader,
    required this.currentUserId,
    required this.canDeleteAnyMessage,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.onDownloadEncryptedAttachment,
    required this.onPreviewEncryptedAttachment,
    required this.onToggleReaction,
  });

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _hovering = false;

  bool get _canEditMessage =>
      widget.message.authorId.isNotEmpty &&
      widget.message.authorId == widget.currentUserId &&
      widget.onEditMessage != null;

  bool get _canDeleteMessage =>
      (_canEditMessage || widget.canDeleteAnyMessage) &&
      widget.onDeleteMessage != null;

  Future<void> _showContextMenu(TapDownDetails details) async {
    if (!_canEditMessage && !_canDeleteMessage) {
      return;
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_MessageAction>(
      context: context,
      color: NewChatColors.panel,
      position: RelativeRect.fromRect(
        Rect.fromPoints(details.globalPosition, details.globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        if (_canEditMessage)
          const PopupMenuItem<_MessageAction>(
            value: _MessageAction.edit,
            child: Text('Edit'),
          ),
        if (_canDeleteMessage)
          const PopupMenuItem<_MessageAction>(
            value: _MessageAction.delete,
            child: Text('Delete'),
          ),
      ],
    );

    switch (selected) {
      case _MessageAction.edit:
        widget.onEditMessage?.call(widget.message);
        break;
      case _MessageAction.delete:
        widget.onDeleteMessage?.call(widget.message);
        break;
      case null:
        break;
    }
  }

  Future<void> _showReactionPicker() async {
    final toggle = widget.onToggleReaction;
    if (toggle == null) return;
    final emoji = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: NewChatColors.panel,
        title: const Text('React'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ['👍', '❤️', '😂', '🎉', '😮', '😢']
                  .map(
                    (value) => ActionChip(
                      label: Text(value, style: const TextStyle(fontSize: 22)),
                      onPressed: () => Navigator.of(dialogContext).pop(value),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
    if (emoji != null) {
      await toggle(widget.message, emoji);
    }
  }

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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _canEditMessage
          ? () => widget.onEditMessage?.call(widget.message)
          : null,
      onSecondaryTapDown: (_canEditMessage || _canDeleteMessage)
          ? _showContextMenu
          : null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: EdgeInsets.fromLTRB(
            12,
            widget.showHeader ? 10 : 2,
            12,
            widget.showHeader ? 5 : 2,
          ),
          decoration: BoxDecoration(
            color: _hovering
                ? Colors.white.withValues(alpha: 0.028)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 46,
                    child: widget.showHeader
                        ? Align(
                            alignment: Alignment.topCenter,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: NewChatColors.panelAlt,
                                borderRadius: BorderRadius.circular(13),
                              ),
                              clipBehavior: Clip.antiAlias,
                              alignment: Alignment.center,
                              child: _MessageAvatar(
                                source: member?.avatarUrl,
                                fallbackInitial: fallbackInitial,
                                animate: _hovering,
                              ),
                            ),
                          )
                        : AnimatedOpacity(
                            duration: const Duration(milliseconds: 100),
                            opacity: _hovering ? 1 : 0,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _formatCompactTime(message.sentAt),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: NewChatColors.textMuted.withValues(
                                    alpha: 0.72,
                                  ),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.showHeader) ...[
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  resolvedName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    height: 1.15,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                time,
                                style: TextStyle(
                                  color: NewChatColors.textMuted.withValues(
                                    alpha: 0.78,
                                  ),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                        ],
                        if (message.content.isNotEmpty)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: _LinkifiedMessageText(
                                  text: message.content,
                                ),
                              ),
                              if (message.isEdited) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '(edited)',
                                  style: TextStyle(
                                    color: NewChatColors.textMuted.withValues(
                                      alpha: 0.72,
                                    ),
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        if (detectedLinks.isNotEmpty &&
                            widget.previewLoader != null) ...[
                          const SizedBox(height: 8),
                          ...detectedLinks
                              .take(2)
                              .map(
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
                          SizedBox(height: message.content.isEmpty ? 2 : 8),
                          ...message.attachments.map(
                            (attachment) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: attachment.url.isEmpty
                                  ? _EncryptedAttachmentTile(
                                      attachment: attachment,
                                      onDownload:
                                          widget.onDownloadEncryptedAttachment,
                                      onPreview:
                                          widget.onPreviewEncryptedAttachment,
                                    )
                                  : attachment.isImage
                                  ? _ImageAttachmentTile(attachment: attachment)
                                  : _FileAttachmentTile(attachment: attachment),
                            ),
                          ),
                        ],
                        if (message.reactions.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: message.reactions
                                .map(
                                  (reaction) => ActionChip(
                                    label: Text(
                                      '${reaction.emoji} ${reaction.count}',
                                    ),
                                    onPressed: widget.onToggleReaction == null
                                        ? null
                                        : () => widget.onToggleReaction!(
                                            message,
                                            reaction.emoji,
                                          ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (_hovering &&
                  (_canEditMessage ||
                      _canDeleteMessage ||
                      widget.onToggleReaction != null))
                Positioned(
                  top: -20,
                  right: 2,
                  child: _MessageHoverActions(
                    canEdit: _canEditMessage,
                    canDelete: _canDeleteMessage,
                    canReact: widget.onToggleReaction != null,
                    onEdit: () => widget.onEditMessage?.call(widget.message),
                    onDelete: () =>
                        widget.onDeleteMessage?.call(widget.message),
                    onReact: _showReactionPicker,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _formatCompactTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _MessageDayDivider extends StatelessWidget {
  final DateTime date;

  const _MessageDayDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final localDate = date.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(
      localDate.year,
      localDate.month,
      localDate.day,
    );
    final difference = today.difference(messageDay).inDays;
    final label = switch (difference) {
      0 => 'Today',
      1 => 'Yesterday',
      _ =>
        '${_monthName(localDate.month)} ${localDate.day}, ${localDate.year}',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: NewChatColors.outline)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                color: NewChatColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Divider(color: NewChatColors.outline)),
        ],
      ),
    );
  }

  String _monthName(int month) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];
}

class _MessageHoverActions extends StatelessWidget {
  final bool canEdit;
  final bool canDelete;
  final bool canReact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReact;

  const _MessageHoverActions({
    required this.canEdit,
    required this.canDelete,
    required this.canReact,
    required this.onEdit,
    required this.onDelete,
    required this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NewChatColors.panelAlt,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: NewChatColors.outline),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canReact)
              _MessageHoverButton(
                icon: Icons.add_reaction_outlined,
                tooltip: 'Add reaction',
                onTap: onReact,
              ),
            if (canEdit)
              _MessageHoverButton(
                icon: Icons.edit_rounded,
                tooltip: 'Edit message',
                onTap: onEdit,
              ),
            if (canDelete)
              _MessageHoverButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Delete message',
                onTap: onDelete,
                destructive: true,
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageHoverButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool destructive;

  const _MessageHoverButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: 17,
            color: destructive
                ? const Color(0xFFFF8E9D)
                : NewChatColors.textMuted,
          ),
        ),
      ),
    );
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

  const _LinkPreviewCard({required this.url, required this.loadPreview});

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
    if (oldWidget.url != widget.url ||
        oldWidget.loadPreview != widget.loadPreview) {
      _future = widget.loadPreview(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreview?>(
      future: _future,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done &&
            preview == null) {
          return const SizedBox.shrink();
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
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
                            : _LinkPreviewLoaded(
                                preview: preview!,
                                fallbackUrl: widget.url,
                              ),
                      ),
                    ),
                  ],
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

class _LinkPreviewLoaded extends StatefulWidget {
  final LinkPreview preview;
  final String fallbackUrl;

  const _LinkPreviewLoaded({required this.preview, required this.fallbackUrl});

  @override
  State<_LinkPreviewLoaded> createState() => _LinkPreviewLoadedState();
}

class _LinkPreviewLoadedState extends State<_LinkPreviewLoaded> {
  WebViewController? _playerController;
  bool _loadingPlayer = false;
  String? _playerError;

  bool _isAllowedPlayerNavigation(String candidate) {
    final initial = Uri.tryParse(widget.preview.mediaUrl);
    final target = Uri.tryParse(candidate);
    if (target == null || initial == null) return false;
    if (target.scheme == 'about') return true;
    return target.scheme == 'https' &&
        target.host.toLowerCase() == initial.host.toLowerCase();
  }

  Future<void> _openPlayer() async {
    final mediaUrl = widget.preview.mediaUrl.trim();
    if (mediaUrl.isEmpty || _loadingPlayer) return;
    setState(() {
      _loadingPlayer = true;
      _playerError = null;
    });
    try {
      final controller = WebViewController(
        onPermissionRequest: (request) {
          request.deny();
        },
      );
      await controller.setUserAgent(
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Safari/537.36 Yappa/0.1',
      );
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            return _isAllowedPlayerNavigation(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (!mounted || error.isForMainFrame != true) return;
            setState(() {
              _playerError = 'This video could not be loaded here.';
            });
          },
        ),
      );
      // YouTube requires an HTTP Referer (or equivalent client identity).
      // Loading its embed as the main WebView request lets every desktop
      // backend send that header reliably; an iframe inside loadHtmlString
      // loses the enclosing-page identity on WebKitGTK.
      await controller.loadRequest(
        Uri.parse(mediaUrl),
        headers: const {'Referer': 'https://app.yappa.invalid/'},
      );
      if (!mounted) return;
      setState(() {
        _playerController = controller;
        _loadingPlayer = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingPlayer = false;
        _playerError = 'Inline playback is unavailable on this device.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final title = preview.title.trim().isNotEmpty
        ? preview.title.trim()
        : preview.launchUrl;
    final description = preview.description.trim();
    final siteName = preview.siteName.trim().isNotEmpty
        ? preview.siteName.trim()
        : (preview.hostname.trim().isNotEmpty
              ? preview.hostname.trim()
              : widget.fallbackUrl);
    final imageUrl = preview.imageUrl.trim();
    final iconUrl = preview.iconUrl.trim();
    final playerController = _playerController;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => _launchExternalUrl(preview.launchUrl),
          borderRadius: BorderRadius.circular(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (imageUrl.isEmpty && iconUrl.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.network(
                    iconUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                  ],
                ),
              ),
            ],
          ),
        ),
        if (playerController != null) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: preview.mediaAspectRatio,
              child: _ViewportContainedWebView(controller: playerController),
            ),
          ),
        ] else if (imageUrl.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: GestureDetector(
              onTap: preview.hasMedia ? _openPlayer : null,
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
                  if (preview.hasMedia)
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                      ),
                      child: _loadingPlayer
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 34),
                    ),
                ],
              ),
            ),
          ),
        ] else if (preview.hasMedia) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loadingPlayer ? null : _openPlayer,
            icon: _loadingPlayer
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Play video'),
          ),
        ],
        if (_playerError != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _playerError!,
                  style: TextStyle(color: NewChatColors.textMuted),
                ),
              ),
              TextButton(
                onPressed: () => _launchExternalUrl(preview.launchUrl),
                child: const Text('Open in browser'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Linux desktop WebViews are native GTK overlays, so Flutter cannot clip
/// them at a scrolling viewport edge. Detach the native surface whenever the
/// complete player is not inside the message viewport. This also prevents the
/// player from painting over the composer while a message scrolls away.
class _ViewportContainedWebView extends StatefulWidget {
  final WebViewController controller;

  const _ViewportContainedWebView({required this.controller});

  @override
  State<_ViewportContainedWebView> createState() =>
      _ViewportContainedWebViewState();
}

class _ViewportContainedWebViewState extends State<_ViewportContainedWebView> {
  final GlobalKey _boundsKey = GlobalKey();
  ScrollPosition? _scrollPosition;
  bool _fullyVisible = false;
  bool _visibilityCheckScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (!identical(nextPosition, _scrollPosition)) {
      _scrollPosition?.removeListener(_scheduleVisibilityCheck);
      _scrollPosition = nextPosition;
      _scrollPosition?.addListener(_scheduleVisibilityCheck);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_scheduleVisibilityCheck);
    super.dispose();
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      final playerBox =
          _boundsKey.currentContext?.findRenderObject() as RenderBox?;
      final viewportBox =
          _scrollPosition?.context.storageContext.findRenderObject()
              as RenderBox?;
      var visible = false;
      if (playerBox != null &&
          viewportBox != null &&
          playerBox.hasSize &&
          viewportBox.hasSize) {
        final playerRect =
            playerBox.localToGlobal(Offset.zero) & playerBox.size;
        final viewportRect =
            viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
        final intersection = playerRect.intersect(viewportRect);
        visible =
            intersection.width >= playerRect.width - 1 &&
            intersection.height >= playerRect.height - 1;
      }
      if (visible != _fullyVisible) {
        setState(() => _fullyVisible = visible);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      key: _boundsKey,
      child: _fullyVisible
          ? WebViewWidget(controller: widget.controller)
          : ColoredBox(
              color: Colors.black,
              child: Center(
                child: Text(
                  'Scroll the video fully into view to play',
                  style: TextStyle(color: NewChatColors.textMuted),
                ),
              ),
            ),
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

class _EncryptedAttachmentTile extends StatefulWidget {
  final ChatAttachment attachment;
  final Future<void> Function(ChatAttachment attachment)? onDownload;
  final Future<void> Function(ChatAttachment attachment, String outputPath)?
  onPreview;

  const _EncryptedAttachmentTile({
    required this.attachment,
    required this.onDownload,
    required this.onPreview,
  });

  @override
  State<_EncryptedAttachmentTile> createState() =>
      _EncryptedAttachmentTileState();
}

class _EncryptedAttachmentTileState extends State<_EncryptedAttachmentTile> {
  bool _downloading = false;
  bool _previewing = false;
  String? _error;

  Future<void> _download() async {
    final download = widget.onDownload;
    if (download == null || _downloading) return;
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      await download(widget.attachment);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = encryptedAttachmentFailureMessage(
          error,
          operation: EncryptedAttachmentOperation.save,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  Future<void> _preview() async {
    final preview = widget.onPreview;
    if (preview == null || _previewing || !widget.attachment.isImage) return;
    setState(() {
      _previewing = true;
      _error = null;
    });
    DecryptedAttachmentPreview? lease;
    try {
      lease = await DecryptedAttachmentPreview.create(widget.attachment);
      await preview(widget.attachment, lease.file.path);
      await lease.protect();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        builder: (context) => _DecryptedImagePreview(file: lease!.file),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = encryptedAttachmentFailureMessage(
          error,
          operation: EncryptedAttachmentOperation.preview,
        );
      });
    } finally {
      await lease?.dispose();
      if (mounted) {
        setState(() {
          _previewing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 430),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: NewChatColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF31584C)),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_rounded, color: Color(0xFF8DD8BC)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    _error ??
                        '${_formatAttachmentBytes(widget.attachment.sizeBytes)}'
                            ' • End-to-end encrypted',
                    style: TextStyle(
                      color: _error == null
                          ? NewChatColors.textMuted
                          : const Color(0xFFFFB4BF),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (widget.attachment.isImage) ...[
              IconButton(
                tooltip: 'Decrypt local preview',
                onPressed:
                    _previewing || _downloading || widget.onPreview == null
                    ? null
                    : _preview,
                icon: _previewing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.visibility_rounded),
              ),
              const SizedBox(width: 4),
            ],
            IconButton(
              tooltip: 'Decrypt and save',
              onPressed:
                  _downloading || _previewing || widget.onDownload == null
                  ? null
                  : _download,
              icon: _downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecryptedImagePreview extends StatelessWidget {
  final File file;

  const _DecryptedImagePreview({required this.file});

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Center(
              child: GestureDetector(
                onTap: () {},
                child: InteractiveViewer(
                  minScale: 0.75,
                  maxScale: 6,
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Text(
                      'Could not render this authenticated image.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 18,
              right: 18,
              child: IconButton.filled(
                tooltip: 'Close and erase local preview',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
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
        PopupMenuItem<String>(value: 'download', child: Text('Download File')),
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
            child: Stack(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 520,
                    maxHeight: 360,
                  ),
                  child: Image.network(
                    widget.attachment.url,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return SizedBox(
                        width: 260,
                        height: 140,
                        child: Center(
                          child: Text(
                            'Could not load image preview',
                            style: TextStyle(color: NewChatColors.textMuted),
                          ),
                        ),
                      );
                    },
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const SizedBox(
                        width: 260,
                        height: 140,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
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
        PopupMenuItem<String>(value: 'download', child: Text('Download File')),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
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
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  Size? _sourceImageSize;
  bool _zoomed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_imageStream != null) {
      return;
    }

    final stream = NetworkImage(
      widget.attachment.url,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, synchronousCall) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sourceImageSize = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
      });
      stream.removeListener(listener);
      _imageStreamListener = null;
    });
    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _imageStreamListener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
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
            final sourceSize = _sourceImageSize ?? viewportSize;
            final imageSize = applyBoxFit(
              BoxFit.contain,
              sourceSize,
              viewportSize,
            ).destination;

            return Stack(
              children: [
                Center(
                  child: GestureDetector(
                    onTapDown: (details) =>
                        _toggleZoomAt(details.localPosition, imageSize),
                    child: SizedBox(
                      width: imageSize.width,
                      height: imageSize.height,
                      child: InteractiveViewer(
                        transformationController: _controller,
                        constrained: false,
                        clipBehavior: Clip.none,
                        boundaryMargin: const EdgeInsets.all(4000),
                        minScale: 1,
                        maxScale: 6,
                        child: SizedBox(
                          width: imageSize.width,
                          height: imageSize.height,
                          child: Image.network(
                            widget.attachment.url,
                            fit: BoxFit.fill,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: 500,
                                height: 260,
                                decoration: BoxDecoration(
                                  color: NewChatColors.panel,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: NewChatColors.outline,
                                  ),
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
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved ${attachment.name}')));
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
