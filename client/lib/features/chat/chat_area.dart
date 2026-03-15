import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;

import '../../app/theme.dart';
import '../../data/audio_preferences.dart';
import '../../data/voice_transport_service.dart';
import '../../models/channel_model.dart';
import '../../models/member_model.dart';
import '../../models/link_preview_model.dart';
import '../../models/message_model.dart';
import '../../models/voice_models.dart';
import '../../shared/avatar_image.dart';
import 'message_input.dart';
import 'message_list.dart';

class ChatArea extends StatefulWidget {
  final ChatChannel channel;
  final List<ChatMessage> messages;
  final ValueChanged<String> onSend;
  final Future<void> Function(String content, List<String> attachmentIds)?
      onSendWithAttachments;
  final Future<ChatAttachment> Function(File file)? onUploadAttachment;
  final Future<LinkPreview?> Function(String url)? onLoadLinkPreview;

  final List<Member> members;
  final List<Member> voiceMembers;
  final VoiceDeckState? voiceDeckState;
  final bool isInSelectedVoiceDeck;
  final bool isBusy;

  final bool micMuted;
  final bool audioMuted;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final bool speaking;

  final bool micPermissionGranted;
  final bool micCaptureActive;
  final double micInputLevel;
  final double micInputPeak;
  final String? micInputError;

  final bool voiceTransportInitialized;
  final bool voiceTransportJoining;
  final bool voiceTransportJoined;
  final bool voiceTransportMicrophoneReady;
  final bool voiceTransportRemoteAudioAttached;
  final String? voiceTransportLocalPeerId;
  final String? voiceTransportChannelId;
  final String? voiceTransportError;
  final Map<String, VoiceTransportPeerState> voiceTransportPeers;
  final String? currentUserId;
  final double Function(String userId)? voiceMemberVolumeForUserId;
  final Future<void> Function(String userId, double volume)? onSetVoiceMemberVolume;
  final livekit.VideoTrack? localCameraTrack;
  final livekit.VideoTrack? localScreenShareTrack;
  final Map<String, livekit.VideoTrack> remoteCameraTracks;
  final Map<String, livekit.VideoTrack> remoteScreenShareTracks;

  final Future<void> Function()? onJoinVoiceDeck;
  final Future<void> Function()? onLeaveVoiceDeck;
  final Future<void> Function(bool value)? onSetMicMuted;
  final Future<void> Function(bool value)? onSetAudioMuted;
  final Future<void> Function(bool value)? onSetCameraEnabled;
  final Future<void> Function(bool value)? onSetScreenShareEnabled;
  final Future<void> Function(bool value)? onSetSpeaking;

  const ChatArea({
    super.key,
    required this.channel,
    required this.messages,
    required this.onSend,
    this.onSendWithAttachments,
    this.onUploadAttachment,
    this.onLoadLinkPreview,
    this.members = const [],
    this.voiceMembers = const [],
    this.voiceDeckState,
    this.isInSelectedVoiceDeck = false,
    this.isBusy = false,
    this.micMuted = false,
    this.audioMuted = false,
    this.cameraEnabled = false,
    this.screenShareEnabled = false,
    this.speaking = false,
    this.micPermissionGranted = false,
    this.micCaptureActive = false,
    this.micInputLevel = 0,
    this.micInputPeak = 0,
    this.micInputError,
    this.voiceTransportInitialized = false,
    this.voiceTransportJoining = false,
    this.voiceTransportJoined = false,
    this.voiceTransportMicrophoneReady = false,
    this.voiceTransportRemoteAudioAttached = false,
    this.voiceTransportLocalPeerId,
    this.voiceTransportChannelId,
    this.voiceTransportError,
    this.voiceTransportPeers = const {},
    this.currentUserId,
    this.voiceMemberVolumeForUserId,
    this.onSetVoiceMemberVolume,
    this.localCameraTrack,
    this.localScreenShareTrack,
    this.remoteCameraTracks = const {},
    this.remoteScreenShareTracks = const {},
    this.onJoinVoiceDeck,
    this.onLeaveVoiceDeck,
    this.onSetMicMuted,
    this.onSetAudioMuted,
    this.onSetCameraEnabled,
    this.onSetScreenShareEnabled,
    this.onSetSpeaking,
  });

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
  final GlobalKey<MessageInputState> _messageInputKey =
      GlobalKey<MessageInputState>();
  final FocusNode _voiceKeyboardFocusNode = FocusNode(
    debugLabel: 'yappa_voice_keyboard_focus',
  );
  final ScrollController _messageScrollController = ScrollController();

  bool _isDragActive = false;
  bool _isNearMessageBottom = true;
  int _unseenMessageCount = 0;
  bool _forceScrollToLatestOnNextMessage = false;
  Timer? _ticker;
  DateTime _now = DateTime.now();
  String? _focusedVoiceMemberId;
  bool _pttPressed = false;
  bool _pttKeyboardDown = false;
  bool _pttMouseDown = false;

  bool get _canAttach =>
      widget.channel.type == ChannelType.text &&
      widget.onUploadAttachment != null;

  bool get _isVoiceDeck => widget.channel.type == ChannelType.voice;

  @override
  void initState() {
    super.initState();
    _messageScrollController.addListener(_handleMessageScroll);
    _syncTicker();
    _syncFocusedParticipant();
    _syncKeyboardFocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLatest(jump: true);
    });
  }

  @override
  void didUpdateWidget(covariant ChatArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
    _syncFocusedParticipant();
    _syncKeyboardFocus();

    if ((!widget.isInSelectedVoiceDeck || !_isVoiceDeck) && _pttPressed) {
      _pttPressed = false;
    }

    if (!_isVoiceDeck) {
      _pttKeyboardDown = false;
      _pttMouseDown = false;
    }

    if (widget.channel.id != oldWidget.channel.id) {
      _unseenMessageCount = 0;
      _isNearMessageBottom = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToLatest(jump: true);
      });
      return;
    }

    if (!_isVoiceDeck && _hasIncomingMessageChange(oldWidget)) {
      final shouldForceScroll = _forceScrollToLatestOnNextMessage;
      _forceScrollToLatestOnNextMessage = false;

      final wasNearBottom = _isNearMessageBottom;
      if (shouldForceScroll || wasNearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToLatest();
        });
      } else {
        final addedCount = widget.messages.length - oldWidget.messages.length;
        if (addedCount > 0) {
          setState(() {
            _unseenMessageCount += addedCount;
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _messageScrollController
      ..removeListener(_handleMessageScroll)
      ..dispose();
    _voiceKeyboardFocusNode.dispose();
    super.dispose();
  }

  bool _hasIncomingMessageChange(ChatArea oldWidget) {
    if (widget.messages.length != oldWidget.messages.length) {
      return true;
    }

    if (widget.messages.isEmpty || oldWidget.messages.isEmpty) {
      return false;
    }

    return widget.messages.last.id != oldWidget.messages.last.id;
  }

  bool _isScrolledNearBottom() {
    if (!_messageScrollController.hasClients) {
      return true;
    }

    final position = _messageScrollController.position;
    return (position.maxScrollExtent - position.pixels) <= 36;
  }

  void _handleMessageScroll() {
    final isNearBottom = _isScrolledNearBottom();
    if (isNearBottom == _isNearMessageBottom &&
        (!isNearBottom || _unseenMessageCount == 0)) {
      return;
    }

    setState(() {
      _isNearMessageBottom = isNearBottom;
      if (isNearBottom) {
        _unseenMessageCount = 0;
      }
    });
  }

  Future<void> _scrollToLatest({bool jump = false}) async {
    if (!_messageScrollController.hasClients) {
      return;
    }

    final position = _messageScrollController.position;
    final target = position.maxScrollExtent;

    if (jump) {
      _messageScrollController.jumpTo(target);
    } else {
      try {
        await _messageScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {}
    }

    _markMessagesAsSeen();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleScrollToLatest();
    });
  }

  void _settleScrollToLatest([int pass = 0]) {
    if (!mounted || !_messageScrollController.hasClients) {
      return;
    }

    final position = _messageScrollController.position;
    final target = position.maxScrollExtent;
    final distance = target - position.pixels;

    if (distance.abs() > 1) {
      _messageScrollController.jumpTo(target);
    }

    _markMessagesAsSeen();

    if (pass < 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _settleScrollToLatest(pass + 1);
      });
    }
  }

  void _markMessagesAsSeen() {
    if (_unseenMessageCount == 0 && _isNearMessageBottom) {
      return;
    }

    setState(() {
      _unseenMessageCount = 0;
      _isNearMessageBottom = true;
    });
  }

  void _handleScrollToLatestPressed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLatest();
    });
  }

  void _handleLocalSend(String content) {
    _forceScrollToLatestOnNextMessage = true;
    widget.onSend(content);
  }

  Future<void> _handleLocalSendWithAttachments(
    String content,
    List<String> attachmentIds,
  ) async {
    _forceScrollToLatestOnNextMessage = true;
    await widget.onSendWithAttachments!(content, attachmentIds);
  }

  void _syncTicker() {
    final shouldTick =
        _isVoiceDeck && widget.voiceDeckState?.activeSince != null;

    if (shouldTick && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _now = DateTime.now();
        });
      });
      return;
    }

    if (!shouldTick && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
      setState(() {
        _now = DateTime.now();
      });
    }
  }

  void _syncKeyboardFocus() {
    if (!_isVoiceDeck) {
      if (_voiceKeyboardFocusNode.hasFocus) {
        _voiceKeyboardFocusNode.unfocus();
      }
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_voiceKeyboardFocusNode.hasFocus) {
        _voiceKeyboardFocusNode.requestFocus();
      }
    });
  }

  void _syncFocusedParticipant() {
    if (!_isVoiceDeck) {
      _focusedVoiceMemberId = null;
      return;
    }

    if (widget.voiceMembers.isEmpty) {
      _focusedVoiceMemberId = null;
      return;
    }

    bool hasLiveScreenShare(Member member) {
      if (member.id == widget.currentUserId) {
        return widget.screenShareEnabled && widget.localScreenShareTrack != null;
      }
      return member.voiceState.screenShareEnabled &&
          widget.remoteScreenShareTracks.containsKey(member.id);
    }

    bool hasLiveCamera(Member member) {
      if (member.id == widget.currentUserId) {
        return widget.localCameraTrack != null;
      }
      return widget.remoteCameraTracks.containsKey(member.id);
    }

    final sharingMember = widget.voiceMembers.cast<Member?>().firstWhere(
          (member) => member != null && hasLiveScreenShare(member),
          orElse: () => null,
        );

    if (sharingMember != null) {
      _focusedVoiceMemberId = sharingMember.id;
      return;
    }

    final cameraMember = widget.voiceMembers.cast<Member?>().firstWhere(
          (member) => member != null && hasLiveCamera(member),
          orElse: () => null,
        );

    if (cameraMember != null && _focusedVoiceMemberId == null) {
      _focusedVoiceMemberId = cameraMember.id;
      return;
    }

    final speakingMember = widget.voiceMembers.cast<Member?>().firstWhere(
          (member) => member?.voiceState.speaking == true,
          orElse: () => null,
        );

    if (speakingMember != null && _focusedVoiceMemberId == null) {
      _focusedVoiceMemberId = speakingMember.id;
      return;
    }

    final stillExists = widget.voiceMembers.any(
      (member) => member.id == _focusedVoiceMemberId,
    );

    if (!stillExists) {
      _focusedVoiceMemberId = widget.voiceMembers.first.id;
    }
  }

  String _formatElapsed(DateTime? since) {
    if (since == null) {
      return '00:00';
    }

    final duration = _now.difference(since.toLocal());
    final safe = duration.isNegative ? Duration.zero : duration;

    final hours = safe.inHours;
    final minutes = safe.inMinutes.remainder(60);
    final seconds = safe.inSeconds.remainder(60);

    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }

    return '$mm:$ss';
  }

  Future<void> _handleDroppedFiles(List<File> files) async {
    if (!_canAttach || files.isEmpty) return;
    await _messageInputKey.currentState?.uploadDroppedFiles(files);
  }

  Future<void> _setSpeakingPressed(bool value) async {
    if (!widget.isInSelectedVoiceDeck) return;
    if (_pttPressed == value) return;

    setState(() {
      _pttPressed = value;
    });

    try {
      await widget.onSetSpeaking?.call(value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pttPressed = !value;
      });
    }
  }

  String _normalizedPttLabel() {
    return YappaAudioPreferences.pushToTalkKeyLabel.trim().toLowerCase();
  }

  bool get _pttModeEnabled =>
      YappaAudioPreferences.voiceInputMode == YappaVoiceInputMode.pushToTalk;

  Set<String> _bindingNamesForLogicalKey(LogicalKeyboardKey key) {
    final names = <String>{};

    final keyLabel = key.keyLabel.trim().toLowerCase();
    if (keyLabel.isNotEmpty) {
      names.add(keyLabel);
    }

    final debugName = (key.debugName ?? '').trim().toLowerCase();
    if (debugName.isNotEmpty) {
      names.add(debugName);
    }

    if (key == LogicalKeyboardKey.space) {
      names.addAll({'space', 'spacebar'});
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      names.addAll({'enter', 'return'});
    }
    if (key == LogicalKeyboardKey.escape) {
      names.addAll({'escape', 'esc'});
    }
    if (key == LogicalKeyboardKey.tab) {
      names.add('tab');
    }
    if (key == LogicalKeyboardKey.backspace) {
      names.add('backspace');
    }
    if (key == LogicalKeyboardKey.shiftLeft) {
      names.addAll({'left shift', 'shift left', 'lshift'});
    }
    if (key == LogicalKeyboardKey.shiftRight) {
      names.addAll({'right shift', 'shift right', 'rshift'});
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      names.add('shift');
    }
    if (key == LogicalKeyboardKey.controlLeft) {
      names.addAll({
        'left ctrl',
        'ctrl left',
        'left control',
        'control left',
        'lctrl',
      });
    }
    if (key == LogicalKeyboardKey.controlRight) {
      names.addAll({
        'right ctrl',
        'ctrl right',
        'right control',
        'control right',
        'rctrl',
      });
    }
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      names.addAll({'ctrl', 'control'});
    }
    if (key == LogicalKeyboardKey.altLeft) {
      names.addAll({'left alt', 'alt left', 'lalt'});
    }
    if (key == LogicalKeyboardKey.altRight) {
      names.addAll({'right alt', 'alt right', 'ralt'});
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      names.add('alt');
    }

    return names;
  }

  bool _matchesKeyboardPttBinding(LogicalKeyboardKey key) {
    final binding = _normalizedPttLabel();
    if (binding.isEmpty || binding.startsWith('mouse')) {
      return false;
    }

    return _bindingNamesForLogicalKey(key).contains(binding);
  }

  int? _mouseButtonMaskForBinding() {
    switch (_normalizedPttLabel()) {
      case 'left mouse':
      case 'mouse 1':
        return kPrimaryMouseButton;
      case 'right mouse':
      case 'mouse 2':
        return kSecondaryMouseButton;
      case 'middle mouse':
      case 'mouse 3':
        return kMiddleMouseButton;
      case 'mouse 4':
      case 'back mouse':
      case 'back button':
        return kBackMouseButton;
      case 'mouse 5':
      case 'forward mouse':
      case 'forward button':
        return kForwardMouseButton;
      default:
        return null;
    }
  }

  void _handleVoiceKeyEvent(KeyEvent event) {
    if (!_isVoiceDeck || !_pttModeEnabled) return;
    if (widget.micMuted) return;

    final key = event.logicalKey;
    if (!_matchesKeyboardPttBinding(key)) return;

    if (event is KeyDownEvent && !_pttKeyboardDown) {
      _pttKeyboardDown = true;
      _setSpeakingPressed(true);
      return;
    }

    if (event is KeyUpEvent) {
      _pttKeyboardDown = false;
      if (!_pttMouseDown) {
        _setSpeakingPressed(false);
      }
    }
  }

  void _handleVoicePointerDown(PointerDownEvent event) {
    if (!_isVoiceDeck || !_pttModeEnabled) return;
    if (widget.micMuted) return;

    final mask = _mouseButtonMaskForBinding();
    if (mask == null) return;

    if ((event.buttons & mask) != 0 && !_pttMouseDown) {
      _pttMouseDown = true;
      _setSpeakingPressed(true);
    }
  }

  void _handleVoicePointerUp(PointerEvent event) {
    if (!_isVoiceDeck) return;

    final mask = _mouseButtonMaskForBinding();
    if (mask == null) return;

    final stillPressed = (event.buttons & mask) != 0;
    if (!stillPressed && _pttMouseDown) {
      _pttMouseDown = false;
      if (!_pttKeyboardDown) {
        _setSpeakingPressed(false);
      }
    }
  }

  Member? get _focusedMember {
    if (_focusedVoiceMemberId == null) return null;
    for (final member in widget.voiceMembers) {
      if (member.id == _focusedVoiceMemberId) {
        return member;
      }
    }
    return null;
  }

  List<Member> get _otherVoiceMembers {
    final focusedId = _focusedMember?.id;
    return widget.voiceMembers
        .where((member) => member.id != focusedId)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      children: [
        Container(
          color: NewChatColors.background,
          child: Column(
            children: [
              if (_isVoiceDeck)
                Expanded(
                  child: _VoiceDeckRoom(
                    channel: widget.channel,
                    isInSelectedVoiceDeck: widget.isInSelectedVoiceDeck,
                    voiceMembers: widget.voiceMembers,
                    focusedMember: _focusedMember,
                    otherMembers: _otherVoiceMembers,
                    elapsedLabel: _formatElapsed(
                      widget.voiceDeckState?.activeSince,
                    ),
                    micMuted: widget.micMuted,
                    audioMuted: widget.audioMuted,
                    cameraEnabled: widget.cameraEnabled,
                    screenShareEnabled: widget.screenShareEnabled,
                    speaking: widget.speaking,
                    isPttPressed: _pttPressed,
                    micPermissionGranted: widget.micPermissionGranted,
                    micCaptureActive: widget.micCaptureActive,
                    micInputLevel: widget.micInputLevel,
                    micInputPeak: widget.micInputPeak,
                    micInputError: widget.micInputError,
                    voiceTransportInitialized: widget.voiceTransportInitialized,
                    voiceTransportJoining: widget.voiceTransportJoining,
                    voiceTransportJoined: widget.voiceTransportJoined,
                    voiceTransportMicrophoneReady:
                        widget.voiceTransportMicrophoneReady,
                    voiceTransportRemoteAudioAttached:
                        widget.voiceTransportRemoteAudioAttached,
                    voiceTransportLocalPeerId: widget.voiceTransportLocalPeerId,
                    voiceTransportChannelId: widget.voiceTransportChannelId,
                    voiceTransportError: widget.voiceTransportError,
                    voiceTransportPeers: widget.voiceTransportPeers,
                    currentUserId: widget.currentUserId,
                    voiceMemberVolumeForUserId:
                        widget.voiceMemberVolumeForUserId,
                    onSetVoiceMemberVolume:
                        widget.onSetVoiceMemberVolume,
                    localCameraTrack: widget.localCameraTrack,
                    localScreenShareTrack: widget.screenShareEnabled
                        ? widget.localScreenShareTrack
                        : null,
                    remoteCameraTracks: widget.remoteCameraTracks,
                    remoteScreenShareTracks:
                        widget.remoteScreenShareTracks,
                    onPttChanged: _isVoiceDeck ? _setSpeakingPressed : null,
                    onFocusMember: (member) {
                      setState(() {
                        _focusedVoiceMemberId = member.id;
                      });
                    },
                  ),
                )
              else ...[
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: MessageList(
                          messages: widget.messages,
                          members: widget.members,
                          controller: _messageScrollController,
                          previewLoader: widget.onLoadLinkPreview,
                        ),
                      ),
                      if (!_isNearMessageBottom)
                        Positioned(
                          right: 28,
                          bottom: 18,
                          child: _ScrollToLatestButton(
                            unseenCount: _unseenMessageCount,
                            onPressed: _handleScrollToLatestPressed,
                          ),
                        ),
                    ],
                  ),
                ),
                MessageInput(
                  key: _messageInputKey,
                  channel: widget.channel,
                  onSend: _handleLocalSend,
                  onSendWithAttachments: widget.onSendWithAttachments == null
                      ? null
                      : _handleLocalSendWithAttachments,
                  onUploadAttachment: widget.onUploadAttachment,
                  dragHandlingEnabled: false,
                ),
              ],
            ],
          ),
        ),
        if (_isDragActive && _canAttach)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.18),
                child: Center(
                  child: Container(
                    width: 420,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: NewChatColors.panel,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: NewChatColors.accentGlow,
                        width: 1.4,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x40100010),
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.file_upload_rounded,
                          size: 28,
                          color: NewChatColors.accentGlow,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Drop files anywhere in this chat to attach them',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return DropTarget(
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

        await _handleDroppedFiles(files);
      },
      child: _isVoiceDeck
          ? Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleVoicePointerDown,
              onPointerUp: _handleVoicePointerUp,
              onPointerCancel: _handleVoicePointerUp,
              child: Focus(
                focusNode: _voiceKeyboardFocusNode,
                autofocus: true,
                onKeyEvent: (_, event) {
                  _handleVoiceKeyEvent(event);
                  return KeyEventResult.ignored;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (!_voiceKeyboardFocusNode.hasFocus) {
                      _voiceKeyboardFocusNode.requestFocus();
                    }
                  },
                  child: content,
                ),
              ),
            )
          : content,
    );
  }
}

class _ScrollToLatestButton extends StatelessWidget {
  final int unseenCount;
  final VoidCallback onPressed;

  const _ScrollToLatestButton({
    required this.unseenCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(22),
            child: Ink(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: NewChatColors.panel.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: NewChatColors.outline),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40100010),
                    blurRadius: 14,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
          if (unseenCount > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: NewChatColors.accent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: NewChatColors.accentGlow,
                    width: 1.2,
                  ),
                ),
                child: Text(
                  unseenCount > 99 ? '99+' : '$unseenCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VoiceDeckRoom extends StatelessWidget {
  final ChatChannel channel;
  final bool isInSelectedVoiceDeck;
  final List<Member> voiceMembers;
  final Member? focusedMember;
  final List<Member> otherMembers;
  final String elapsedLabel;
  final bool micMuted;
  final bool audioMuted;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final bool speaking;
  final bool isPttPressed;
  final bool micPermissionGranted;
  final bool micCaptureActive;
  final double micInputLevel;
  final double micInputPeak;
  final String? micInputError;
  final bool voiceTransportInitialized;
  final bool voiceTransportJoining;
  final bool voiceTransportJoined;
  final bool voiceTransportMicrophoneReady;
  final bool voiceTransportRemoteAudioAttached;
  final String? voiceTransportLocalPeerId;
  final String? voiceTransportChannelId;
  final String? voiceTransportError;
  final Map<String, VoiceTransportPeerState> voiceTransportPeers;
  final String? currentUserId;
  final double Function(String userId)? voiceMemberVolumeForUserId;
  final Future<void> Function(String userId, double volume)? onSetVoiceMemberVolume;
  final livekit.VideoTrack? localCameraTrack;
  final livekit.VideoTrack? localScreenShareTrack;
  final Map<String, livekit.VideoTrack> remoteCameraTracks;
  final Map<String, livekit.VideoTrack> remoteScreenShareTracks;
  final Future<void> Function(bool value)? onPttChanged;
  final ValueChanged<Member> onFocusMember;

  const _VoiceDeckRoom({
    required this.channel,
    required this.isInSelectedVoiceDeck,
    required this.voiceMembers,
    required this.focusedMember,
    required this.otherMembers,
    required this.elapsedLabel,
    required this.micMuted,
    required this.audioMuted,
    required this.cameraEnabled,
    required this.screenShareEnabled,
    required this.speaking,
    required this.isPttPressed,
    required this.micPermissionGranted,
    required this.micCaptureActive,
    required this.micInputLevel,
    required this.micInputPeak,
    required this.micInputError,
    required this.voiceTransportInitialized,
    required this.voiceTransportJoining,
    required this.voiceTransportJoined,
    required this.voiceTransportMicrophoneReady,
    required this.voiceTransportRemoteAudioAttached,
    required this.voiceTransportLocalPeerId,
    required this.voiceTransportChannelId,
    required this.voiceTransportError,
    required this.voiceTransportPeers,
    required this.currentUserId,
    required this.voiceMemberVolumeForUserId,
    required this.onSetVoiceMemberVolume,
    required this.localCameraTrack,
    required this.localScreenShareTrack,
    required this.remoteCameraTracks,
    required this.remoteScreenShareTracks,
    required this.onPttChanged,
    required this.onFocusMember,
  });

  double _volumeFor(Member member) {
    return voiceMemberVolumeForUserId?.call(member.id) ?? 1.0;
  }

  Future<void> _showVolumeMenu(
    BuildContext context,
    Member member,
    TapDownDetails details,
  ) async {
    if (member.id == currentUserId) {
      return;
    }

    final callback = onSetVoiceMemberVolume;
    if (callback == null) {
      return;
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final currentVolume = _volumeFor(member);

    final selected = await showMenu<double>(
      context: context,
      color: NewChatColors.panel,
      position: RelativeRect.fromRect(
        Rect.fromPoints(details.globalPosition, details.globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<double>(
          enabled: false,
          child: Text(
            '${member.name} • ${(currentVolume * 100).round()}%',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<double>(value: 0.0, child: Text('Mute • 0%')),
        const PopupMenuItem<double>(value: 0.25, child: Text('Very quiet • 25%')),
        const PopupMenuItem<double>(value: 0.5, child: Text('Half volume • 50%')),
        const PopupMenuItem<double>(value: 0.75, child: Text('Lower volume • 75%')),
        const PopupMenuItem<double>(value: 1.0, child: Text('Normal • 100%')),
        const PopupMenuItem<double>(value: 1.25, child: Text('Boost • 125%')),
        const PopupMenuItem<double>(value: 1.5, child: Text('Boost more • 150%')),
      ],
    );

    if (selected == null) {
      return;
    }

    await callback(member.id, selected);
    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${member.name} volume set to ${(selected * 100).round()}% for you.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    livekit.VideoTrack? cameraTrackFor(Member member) {
      if (member.id == currentUserId) {
        return localCameraTrack;
      }
      return remoteCameraTracks[member.id];
    }

    livekit.VideoTrack? screenShareTrackFor(Member member) {
      if (member.id == currentUserId) {
        return screenShareEnabled ? localScreenShareTrack : null;
      }
      if (!member.voiceState.screenShareEnabled) {
        return null;
      }
      return remoteScreenShareTracks[member.id];
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const outerGap = 16.0;
        const stripHeight = 136.0;
        final hasStrip = otherMembers.isNotEmpty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, outerGap, 18, outerGap),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: NewChatColors.panelAlt,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: NewChatColors.outline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: focusedMember == null
                        ? _VoiceDeckEmptyState(
                            channelName: channel.name,
                            isInSelectedVoiceDeck: isInSelectedVoiceDeck,
                          )
                        : _VoiceStageTile(
                            member: focusedMember!,
                            isFocused: true,
                            isLocalUser: focusedMember!.id == currentUserId,
                            localMicMuted: micMuted,
                            localAudioMuted: audioMuted,
                            localCameraEnabled: cameraEnabled,
                            localScreenShareEnabled: screenShareEnabled,
                            localSpeaking: speaking,
                            localMicCaptureActive: micCaptureActive,
                            cameraTrack: cameraTrackFor(focusedMember!),
                            screenShareTrack:
                                screenShareTrackFor(focusedMember!),
                            elapsedLabel: elapsedLabel,
                            onSecondaryTapDown: focusedMember!.id == currentUserId
                                ? null
                                : (details) => _showVolumeMenu(
                                      context,
                                      focusedMember!,
                                      details,
                                    ),
                          ),
                  ),
                ),
              ),
              if (hasStrip) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: stripHeight,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.view_carousel_rounded,
                                color: NewChatColors.textMuted, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Other people in ${channel.name}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: otherMembers.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              final member = otherMembers[index];
                              return _MiniVoiceTile(
                                member: member,
                                cameraTrack: cameraTrackFor(member),
                                screenShareTrack: screenShareTrackFor(member),
                                onTap: () => onFocusMember(member),
                                onSecondaryTapDown: member.id == currentUserId
                                    ? null
                                    : (details) => _showVolumeMenu(
                                          context,
                                          member,
                                          details,
                                        ),
                                volumeLabel: member.id == currentUserId ||
                                        (_volumeFor(member) - 1.0).abs() < 0.001
                                    ? null
                                    : '${(_volumeFor(member) * 100).round()}%',
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _VoiceDeckEmptyState extends StatelessWidget {
  final String channelName;
  final bool isInSelectedVoiceDeck;

  const _VoiceDeckEmptyState({
    required this.channelName,
    required this.isInSelectedVoiceDeck,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: NewChatColors.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: NewChatColors.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isInSelectedVoiceDeck
                    ? Icons.multitrack_audio_rounded
                    : Icons.headset_rounded,
                size: 48,
                color: NewChatColors.warning,
              ),
              const SizedBox(height: 18),
              Text(
                isInSelectedVoiceDeck
                    ? 'Waiting for more people in $channelName'
                    : 'Join $channelName to enter the deck',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                'Camera feeds and screen shares appear here automatically once someone enables them in the deck.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceStageTile extends StatelessWidget {
  final Member member;
  final bool isFocused;
  final bool isLocalUser;
  final bool localMicMuted;
  final bool localAudioMuted;
  final bool localCameraEnabled;
  final bool localScreenShareEnabled;
  final bool localSpeaking;
  final bool localMicCaptureActive;
  final livekit.VideoTrack? cameraTrack;
  final livekit.VideoTrack? screenShareTrack;
  final String elapsedLabel;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;

  const _VoiceStageTile({
    required this.member,
    required this.isFocused,
    required this.isLocalUser,
    required this.localMicMuted,
    required this.localAudioMuted,
    required this.localCameraEnabled,
    required this.localScreenShareEnabled,
    required this.localSpeaking,
    required this.localMicCaptureActive,
    required this.cameraTrack,
    required this.screenShareTrack,
    required this.elapsedLabel,
    this.onSecondaryTapDown,
  });

  bool get _cameraActive => isLocalUser
      ? (localCameraEnabled && cameraTrack != null)
      : (cameraTrack != null || member.voiceState.cameraEnabled);

  bool get _screenShareActive => isLocalUser
      ? (localScreenShareEnabled && screenShareTrack != null)
      : (member.voiceState.screenShareEnabled && screenShareTrack != null);

  bool get _micMutedActive =>
      isLocalUser ? localMicMuted : member.voiceState.micMuted;

  bool get _audioMutedActive =>
      isLocalUser ? localAudioMuted : member.voiceState.audioMuted;

  bool get _speakingActive =>
      isLocalUser ? localSpeaking : member.voiceState.speaking;

  bool get _mutedVisualActive => _micMutedActive || _audioMutedActive;

  Color get _activeBorderColor {
    if (_mutedVisualActive) {
      return const Color(0xFFFF667E);
    }
    if (_speakingActive) {
      return const Color(0xFF54D17A);
    }
    return Colors.transparent;
  }

  List<BoxShadow>? get _activeBorderShadow {
    if (_mutedVisualActive) {
      return const [
        BoxShadow(
          color: Color(0x22FF667E),
          blurRadius: 18,
          offset: Offset(0, 0),
          spreadRadius: 1,
        ),
      ];
    }
    if (_speakingActive) {
      return const [
        BoxShadow(
          color: Color(0x2254D17A),
          blurRadius: 18,
          offset: Offset(0, 0),
          spreadRadius: 1,
        ),
      ];
    }
    return null;
  }

  Widget _buildPrimaryMedia() {
    final activeTrack = screenShareTrack ?? cameraTrack;
    final isLiveScreenShare = screenShareTrack != null;
    final isLiveCamera = cameraTrack != null;
    final avatarSize = _screenShareActive ? 146.0 : 180.0;

    if (activeTrack != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(_screenShareActive ? 24 : 92),
        child: Stack(
          fit: StackFit.expand,
          children: [
            livekit.VideoTrackRenderer(
              activeTrack,
              fit: isLiveScreenShare
                  ? livekit.VideoViewFit.contain
                  : livekit.VideoViewFit.cover,
              mirrorMode: isLocalUser && isLiveCamera
                  ? livekit.VideoViewMirrorMode.mirror
                  : livekit.VideoViewMirrorMode.auto,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.06),
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.28),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_screenShareActive) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.screen_share_rounded,
            size: 40,
            color: Color(0xFF54D17A),
          ),
          const SizedBox(height: 10),
          Text(
            '${member.name} sharing',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ],
      );
    }

    if (_cameraActive) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_rounded,
            size: 42,
            color: Color(0xFF54D17A),
          ),
          const SizedBox(height: 10),
          Text(
            '${member.name} camera',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ],
      );
    }

    return _VoiceAvatarBubble(
      member: member,
      size: avatarSize,
      animate: true,
      borderRadius: BorderRadius.circular(avatarSize / 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeTrack = screenShareTrack ?? cameraTrack;
    final hasLiveMedia = activeTrack != null;

    return MouseRegion(
      cursor: onSecondaryTapDown != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: onSecondaryTapDown,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF10161E),
            Color(0xFF141A22),
            Color(0xFF10151D),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: _activeBorderColor,
          width: _activeBorderColor == Colors.transparent ? 0.9 : 1.6,
        ),
        boxShadow: _activeBorderShadow,
      ),
      child: Stack(
        children: [
          if (hasLiveMedia)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.black),
                    livekit.VideoTrackRenderer(
                      activeTrack,
                      fit: screenShareTrack != null
                          ? livekit.VideoViewFit.contain
                          : livekit.VideoViewFit.cover,
                      mirrorMode: isLocalUser && screenShareTrack == null
                          ? livekit.VideoViewMirrorMode.mirror
                          : livekit.VideoViewMirrorMode.auto,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.08),
                            Colors.black.withValues(alpha: 0.0),
                            Colors.black.withValues(alpha: 0.36),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: _screenShareActive ? 230 : 184,
                    height: _screenShareActive ? 150 : 184,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        _screenShareActive ? 24 : 92,
                      ),
                      color: _screenShareActive
                          ? const Color(0xFF17202B)
                          : const Color(0xFF1E2630),
                      border: Border.all(
                        color: Colors.transparent,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Center(
                      child: _buildPrimaryMedia(),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 18,
            child: Center(
              child: _StageIdentityPill(
                label: member.name,
                micMuted: _micMutedActive,
                audioMuted: _audioMutedActive,
              ),
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}

class _MiniVoiceTile extends StatelessWidget {
  final Member member;
  final livekit.VideoTrack? cameraTrack;
  final livekit.VideoTrack? screenShareTrack;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;
  final String? volumeLabel;

  const _MiniVoiceTile({
    required this.member,
    required this.cameraTrack,
    required this.screenShareTrack,
    required this.onTap,
    this.onSecondaryTapDown,
    this.volumeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final activeTrack = screenShareTrack ?? cameraTrack;

    return MouseRegion(
      cursor: onSecondaryTapDown != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: onSecondaryTapDown,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 148,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NewChatColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: member.voiceState.micMuted || member.voiceState.audioMuted
                ? const Color(0xFFFF667E)
                : member.voiceState.speaking
                    ? const Color(0xFF54D17A)
                    : Colors.transparent,
          ),
          boxShadow: member.voiceState.micMuted || member.voiceState.audioMuted
              ? const [
                  BoxShadow(
                    color: Color(0x18FF667E),
                    blurRadius: 14,
                    offset: Offset(0, 0),
                    spreadRadius: 1,
                  ),
                ]
              : member.voiceState.speaking
                  ? const [
                      BoxShadow(
                        color: Color(0x1854D17A),
                        blurRadius: 14,
                        offset: Offset(0, 0),
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: activeTrack != null
                            ? Colors.black
                            : member.role == 'owner'
                                ? const Color(0xFF2C2214)
                                : NewChatColors.panelAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: member.voiceState.micMuted ||
                                  member.voiceState.audioMuted
                              ? const Color(0xFFFF667E)
                              : member.voiceState.speaking
                                  ? const Color(0xFF54D17A)
                                  : Colors.transparent,
                        ),
                      ),
                      child: activeTrack != null
                          ? livekit.VideoTrackRenderer(
                              activeTrack,
                              fit: screenShareTrack != null
                                  ? livekit.VideoViewFit.cover
                                  : livekit.VideoViewFit.cover,
                              mirrorMode: livekit.VideoViewMirrorMode.auto,
                            )
                          : _VoiceAvatarBubble(
                              member: member,
                              size: 42,
                              animate: true,
                              borderRadius: BorderRadius.circular(14),
                            ),
                    ),
                    if (member.isOwner)
                      Positioned(
                        left: -4,
                        top: -9,
                        child: Transform.rotate(
                          angle: -0.42,
                          alignment: Alignment.bottomRight,
                          child: const Text(
                            '👑',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                if (member.voiceState.speaking)
                  const _MiniTileStatusIcon(
                    icon: Icons.graphic_eq_rounded,
                    color: Color(0xFF54D17A),
                  )
                else if (member.voiceState.screenShareEnabled)
                  const _MiniTileStatusIcon(
                    icon: Icons.screen_share_rounded,
                    color: Color(0xFF54D17A),
                  )
                else if (member.voiceState.cameraEnabled)
                  const _MiniTileStatusIcon(
                    icon: Icons.videocam_rounded,
                    color: Color(0xFF54D17A),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (member.voiceState.speaking)
                  const _MiniTileStatusIcon(
                    icon: Icons.graphic_eq_rounded,
                    color: Color(0xFF54D17A),
                  ),
                if (member.voiceState.micMuted)
                  const _MiniTileStatusIcon(
                    icon: Icons.mic_off_rounded,
                    color: Color(0xFFFF667E),
                  ),
                if (member.voiceState.audioMuted)
                  const _MiniTileStatusIcon(
                    icon: Icons.volume_off_rounded,
                    color: Color(0xFFFF667E),
                  ),
                if (member.voiceState.cameraEnabled)
                  const _MiniTileStatusIcon(
                    icon: Icons.videocam_rounded,
                    color: Color(0xFF54D17A),
                  ),
                if (member.voiceState.screenShareEnabled)
                  const _MiniTileStatusIcon(
                    icon: Icons.screen_share_rounded,
                    color: Color(0xFF54D17A),
                  ),
                if (!member.voiceState.speaking &&
                    !member.voiceState.micMuted &&
                    !member.voiceState.audioMuted &&
                    !member.voiceState.cameraEnabled &&
                    !member.voiceState.screenShareEnabled)
                  Text(
                    'Click to focus',
                    style: TextStyle(
                      color: NewChatColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                if (volumeLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    child: Text(
                      volumeLabel!,
                      style: TextStyle(
                        color: NewChatColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}


class _VoiceAvatarBubble extends StatelessWidget {
  final Member member;
  final double size;
  final bool animate;
  final BorderRadius borderRadius;

  const _VoiceAvatarBubble({
    required this.member,
    required this.size,
    required this.animate,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        (member.name.isNotEmpty ? member.name.characters.first : '?')
            .toUpperCase();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: member.isOwner
            ? const Color(0xFF2A2113)
            : const Color(0xFF1E2630),
        borderRadius: borderRadius,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: AvatarImage(
          source: member.avatarUrl,
          fallbackInitial: initial,
          size: size,
          animate: animate,
        ),
      ),
    );
  }
}

class _MiniTileStatusIcon extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _MiniTileStatusIcon({
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: NewChatColors.panelAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Icon(
        icon,
        size: 13,
        color: color,
      ),
    );
  }
}

class _StageIdentityPill extends StatelessWidget {
  final String label;
  final bool micMuted;
  final bool audioMuted;

  const _StageIdentityPill({
    required this.label,
    required this.micMuted,
    required this.audioMuted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (micMuted || audioMuted) const SizedBox(width: 10),
          if (micMuted)
            const Icon(
              Icons.mic_off_rounded,
              size: 15,
              color: Color(0xFFFF667E),
            ),
          if (micMuted && audioMuted) const SizedBox(width: 8),
          if (audioMuted)
            const Icon(
              Icons.volume_off_rounded,
              size: 15,
              color: Color(0xFFFFD37A),
            ),
        ],
      ),
    );
  }
}
