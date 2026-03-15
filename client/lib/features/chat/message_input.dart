import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../models/channel_model.dart';
import '../../models/message_model.dart';

class MessageInput extends StatefulWidget {
  final ChatChannel channel;
  final ValueChanged<String> onSend;
  final Future<void> Function(String content, List<String> attachmentIds)?
      onSendWithAttachments;
  final Future<ChatAttachment> Function(File file)? onUploadAttachment;
  final bool dragHandlingEnabled;

  const MessageInput({
    super.key,
    required this.channel,
    required this.onSend,
    this.onSendWithAttachments,
    this.onUploadAttachment,
    this.dragHandlingEnabled = true,
  });

  @override
  State<MessageInput> createState() => MessageInputState();
}

class _SubmitMessageIntent extends Intent {
  const _SubmitMessageIntent();
}

class MessageInputState extends State<MessageInput> {
  late final TextEditingController _controller;
  final List<ChatAttachment> _pendingAttachments = [];
  bool _isUploading = false;
  bool _isSending = false;
  bool _isDragActive = false;
  String? _uploadError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canAttach =>
      widget.channel.type == ChannelType.text && widget.onUploadAttachment != null;

  Future<void> uploadDroppedFiles(List<File> files) async {
    await _uploadFiles(files);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    if (widget.onSendWithAttachments != null) {
      setState(() {
        _isSending = true;
        _uploadError = null;
      });

      try {
        await widget.onSendWithAttachments!(
          text,
          _pendingAttachments.map((item) => item.id).toList(),
        );

        if (!mounted) return;
        _controller.clear();
        setState(() {
          _pendingAttachments.clear();
        });
      } finally {
        if (mounted) {
          setState(() {
            _isSending = false;
          });
        }
      }

      return;
    }

    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _pickFiles() async {
    if (!_canAttach || _isUploading || _isSending) return;

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      lockParentWindow: true,
      type: FileType.any,
    );

    if (result == null || result.files.isEmpty) {
      return;
    }

    final files = <File>[];
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null || path.isEmpty) continue;
      files.add(File(path));
    }

    if (files.isEmpty) return;
    await _uploadFiles(files);
  }

  Future<void> _uploadFiles(List<File> files) async {
    if (!_canAttach || _isUploading || _isSending) return;

    setState(() {
      _isUploading = true;
      _uploadError = null;
    });

    try {
      for (final file in files) {
        if (!file.existsSync()) continue;

        try {
          final attachment = await widget.onUploadAttachment!(file);
          if (!mounted) return;

          setState(() {
            final exists =
                _pendingAttachments.any((item) => item.id == attachment.id);
            if (!exists) {
              _pendingAttachments.add(attachment);
            }
          });
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _uploadError = error.toString().replaceFirst('Exception: ', '');
          });
          break;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  void _removePendingAttachment(String attachmentId) {
    setState(() {
      _pendingAttachments.removeWhere((item) => item.id == attachmentId);
    });
  }

  Widget _buildComposer() {
    final hintText = widget.channel.type == ChannelType.text
        ? 'Drop a message into ${widget.channel.name}'
        : 'Leave a note in ${widget.channel.name}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _isDragActive
              ? NewChatColors.surface.withValues(alpha: 0.7)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color:
                _isDragActive ? NewChatColors.accentGlow : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isDragActive && _canAttach)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: NewChatColors.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: NewChatColors.outline),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.file_upload_rounded,
                      color: NewChatColors.accentGlow,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Drop files here to attach them',
                        style: TextStyle(
                          color: NewChatColors.textMuted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_pendingAttachments.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NewChatColors.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: NewChatColors.outline),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _pendingAttachments
                      .map(
                        (attachment) => _PendingAttachmentChip(
                          attachment: attachment,
                          onRemove: () =>
                              _removePendingAttachment(attachment.id),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (_uploadError != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF241217),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF6B2833)),
                ),
                child: Text(
                  _uploadError!,
                  style: const TextStyle(color: Color(0xFFFFB4BF)),
                ),
              ),
            Row(
              children: [
                _ComposerTool(
                  icon: Icons.attach_file_rounded,
                  onTap: _canAttach ? _pickFiles : null,
                  busy: _isUploading,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Shortcuts(
                    shortcuts: <ShortcutActivator, Intent>{
                      SingleActivator(LogicalKeyboardKey.enter):
                          const _SubmitMessageIntent(),
                      SingleActivator(LogicalKeyboardKey.numpadEnter):
                          const _SubmitMessageIntent(),
                    },
                    child: Actions(
                      actions: <Type, Action<Intent>>{
                        _SubmitMessageIntent: CallbackAction<_SubmitMessageIntent>(
                          onInvoke: (intent) {
                            _submit();
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        controller: _controller,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        minLines: 1,
                        maxLines: 6,
                        decoration: InputDecoration(
                          hintText: hintText,
                          prefixIcon: const Icon(
                            Icons.subdirectory_arrow_right_rounded,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _isSending ? null : _submit,
                  child: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.dragHandlingEnabled) {
      return _buildComposer();
    }

    return DropTarget(
      onDragDone: (detail) async {
        if (!_canAttach) return;

        final files = <File>[];
        for (final item in detail.files) {
          final path = item.path;
          if (path.isEmpty) continue;
          files.add(File(path));
        }

        if (mounted) {
          setState(() {
            _isDragActive = false;
          });
        }

        if (files.isEmpty) return;
        await _uploadFiles(files);
      },
      onDragEntered: (_) {
        if (!_canAttach) return;
        setState(() {
          _isDragActive = true;
        });
      },
      onDragExited: (_) {
        if (!_canAttach) return;
        setState(() {
          _isDragActive = false;
        });
      },
      child: _buildComposer(),
    );
  }
}

class _ComposerTool extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  const _ComposerTool({
    required this.icon,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;

    return InkWell(
      onTap: disabled || busy ? null : onTap,
      mouseCursor: disabled || busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: disabled ? NewChatColors.panelAlt : NewChatColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: NewChatColors.outline),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                icon,
                color: disabled
                    ? NewChatColors.textMuted.withValues(alpha: 0.5)
                    : NewChatColors.textMuted,
              ),
      ),
    );
  }
}

class _PendingAttachmentChip extends StatelessWidget {
  final ChatAttachment attachment;
  final VoidCallback onRemove;

  const _PendingAttachmentChip({
    required this.attachment,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isImage = attachment.isImage;

    return Container(
      width: isImage ? 164 : 260,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                height: 110,
                width: double.infinity,
                color: Colors.transparent,
                child: Image.network(
                  attachment.url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: NewChatColors.textMuted,
                      ),
                    );
                  },
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  },
                ),
              ),
            )
          else
            Row(
              children: [
                Icon(
                  attachment.isVideo
                      ? Icons.movie_rounded
                      : attachment.isAudio
                          ? Icons.audiotrack_rounded
                          : Icons.insert_drive_file_rounded,
                  size: 16,
                  color: NewChatColors.accentGlow,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    attachment.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  attachment.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              InkWell(
                onTap: onRemove,
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close_rounded, size: 16),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}