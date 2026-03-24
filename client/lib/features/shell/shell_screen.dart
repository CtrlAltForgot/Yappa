import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../models/member_model.dart';
import '../../models/server_model.dart';
import '../../shared/avatar_image.dart';
import '../admin/server_admin_dialog.dart';
import '../channels/channel_sidebar.dart';
import '../chat/chat_area.dart';
import '../connect/connect_screen.dart';
import '../members/member_sidebar.dart';
import '../settings/yappa_settings_dialog.dart';
import '../settings/user_settings_dialog.dart';
import '../../data/voice_transport_service.dart';

class ShellScreen extends StatefulWidget {
  final AppState appState;

  const ShellScreen({super.key, required this.appState});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  double _channelSidebarWidth = 270;
  double _memberSidebarWidth = 280;
  bool _screenShareToggleInFlight = false;

  Future<void> _showAddServerDialog(BuildContext context) async {
    final addressController = TextEditingController();
    String? dialogError;

    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: const Text('Add server node'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: addressController,
                      decoration: const InputDecoration(
                        labelText: 'IP / host / domain',
                        hintText: '127.0.0.1',
                        prefixIcon: Icon(Icons.router_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (dialogError == null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Yappa will connect to the node and use the real server name from the backend.',
                          style: TextStyle(
                            color: NewChatColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      Text(
                        dialogError!,
                        style: const TextStyle(color: Color(0xFFFFB4BF)),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () {
                    final address = addressController.text.trim();

                    if (address.isEmpty) {
                      setModalState(() {
                        dialogError = 'Enter a server address.';
                      });
                      return;
                    }

                    Navigator.of(dialogContext).pop(address);
                  },
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('Add Node'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || result.isEmpty) {
      return;
    }

    try {
      await widget.appState.addServerNode(address: result);
    } catch (_) {}
  }

  Future<void> _showOwnerPanel(BuildContext context) async {
    if (!widget.appState.canManageSelectedServer) {
      return;
    }

    await showServerAdminDialog(
      context,
      appState: widget.appState,
    );
  }

  Future<void> _showSettingsDialog(BuildContext context) async {
    await showYappaSettingsDialog(
      context: context,
      appState: widget.appState,
      onThemeChanged: () {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  Future<void> _showUserSettingsDialog(BuildContext context) async {
    await showUserSettingsDialog(context: context, appState: widget.appState);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _joinSelectedVoiceDeck() async {
    final channel = widget.appState.selectedChannel;
    if (channel.type.name != 'voice') {
      return;
    }

    try {
      await widget.appState.joinVoiceDeck(channel.id);
    } catch (_) {}
  }

  Future<void> _leaveSelectedVoiceDeck() async {
    try {
      await widget.appState.leaveVoiceDeck();
    } catch (_) {}
  }

  Future<void> _setSelectedMicMuted(bool value) async {
    try {
      await widget.appState.updateSelectedVoiceState(micMuted: value);
    } catch (_) {}
  }

  Future<void> _setSelectedAudioMuted(bool value) async {
    try {
      await widget.appState.updateSelectedVoiceState(audioMuted: value);
    } catch (_) {}
  }

  Future<void> _setSelectedCameraEnabled(bool value) async {
    try {
      await widget.appState.setSelectedCameraEnabled(value);
    } catch (_) {}
  }

  Future<void> _setSelectedScreenShareEnabled(bool value) async {
    if (_screenShareToggleInFlight) {
      return;
    }

    _screenShareToggleInFlight = true;
    try {
      if (!value) {
        await widget.appState.setSelectedScreenShareEnabled(false);
        return;
      }

      await widget.appState.setSelectedScreenShareEnabled(
        true,
        preferredTarget: VoiceScreenShareTarget.screen,
      );
    } catch (error) {
      if (!mounted) return;
      final message = widget.appState.voiceTransportError ??
          'Could not start screen share: $error';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(message)),
        );
    } finally {
      _screenShareToggleInFlight = false;
    }
  }

  Future<void> _setSelectedSpeaking(bool value) async {
    try {
      await widget.appState.updateSelectedSpeaking(value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (widget.appState.isOnHome) {
      return ConnectScreen(appState: widget.appState);
    }

    final selectedChannel = widget.appState.selectedChannel;
    final isVoiceDeck = selectedChannel.type.name == 'voice';
    final isInSelectedVoiceDeck =
        widget.appState.isCurrentUserInVoiceDeck(selectedChannel.id);

    return Scaffold(
      body: Column(
        children: [
          _TopFrameBar(
            appState: widget.appState,
            onOpenUserSettings: () => _showUserSettingsDialog(context),
            onOpenSettings: () => _showSettingsDialog(context),
            onOpenAdminPanel: widget.appState.isSelectedServerOwner
                ? () => _showOwnerPanel(context)
                : null,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const railWidth = 88.0;
                const minChannelSidebarWidth = 252.0;
                const minMemberSidebarWidth = 160.0;

                final totalWidth = constraints.maxWidth;

                final centerMin = totalWidth >= 1400
                    ? 720.0
                    : totalWidth >= 1180
                        ? 560.0
                        : totalWidth >= 980
                            ? 420.0
                            : 320.0;

                final maxSideBudget = totalWidth - railWidth - centerMin;

                double leftWidth = _channelSidebarWidth;
                double rightWidth = _memberSidebarWidth;

                if (maxSideBudget < (minChannelSidebarWidth + minMemberSidebarWidth)) {
                  leftWidth = minChannelSidebarWidth;
                  rightWidth = minMemberSidebarWidth;
                } else if (leftWidth + rightWidth > maxSideBudget) {
                  final totalDesired = leftWidth + rightWidth;
                  leftWidth = (leftWidth / totalDesired) * maxSideBudget;
                  rightWidth = (rightWidth / totalDesired) * maxSideBudget;
                }

                leftWidth = leftWidth.clamp(minChannelSidebarWidth, 360.0);
                rightWidth = rightWidth.clamp(minMemberSidebarWidth, 360.0);

                return Row(
                  children: [
                    SizedBox(
                      width: railWidth,
                      child: _HomeAndServerRail(
                        servers: widget.appState.servers,
                        selectedServerId: widget.appState.selectedServerId,
                        onGoHome: () {
                          widget.appState.goHome();
                        },
                        onServerSelected: (serverId) {
                          widget.appState.openServer(serverId);
                        },
                        onAddServer: () {
                          _showAddServerDialog(context);
                        },
                      ),
                    ),
                    SizedBox(
                      width: leftWidth,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: ChannelSidebar(
                              server: widget.appState.selectedServer,
                              channels: widget.appState.channelsForSelectedServer,
                              members: widget.appState.selectedMembers,
                              voiceDeckStates:
                                  widget.appState.selectedVoiceDeckStates,
                              selectedChannelId:
                                  widget.appState.selectedChannelId,
                              onChannelSelected: (channelId) {
                                widget.appState.selectChannel(channelId);
                              },
                              onVoiceDeckDoubleTap: (channelId) async {
                                widget.appState.selectChannel(channelId);
                                try {
                                  await widget.appState.joinVoiceDeck(channelId);
                                } catch (_) {}
                              },
                              canOpenAdminPanel:
                                  widget.appState.canManageSelectedServer,
                              onOpenAdminPanel:
                                  widget.appState.canManageSelectedServer
                                      ? () => _showOwnerPanel(context)
                                      : null,
                              currentUserId:
                                  widget.appState.currentUserIdForSelectedServer,
                              voiceMemberVolumeForUserId:
                                  widget.appState.voiceMemberVolumeFor,
                              onSetVoiceMemberVolume: (userId, volume) {
                                return widget.appState.setVoiceMemberVolume(
                                  userId: userId,
                                  volume: volume,
                                );
                              },
                              bottomDock: _SidebarVoiceControlDock(
                                canJoinSelectedChannel: isVoiceDeck,
                                isInSelectedVoiceDeck: isInSelectedVoiceDeck,
                                isBusy: widget.appState.isBusy,
                                micMuted: widget.appState.selectedMicMuted,
                                audioMuted: widget.appState.selectedAudioMuted,
                                cameraEnabled:
                                    widget.appState.selectedCameraEnabled,
                                screenShareEnabled:
                                    widget.appState.selectedScreenShareEnabled,
                                onJoinLeave: () async {
                                  if (!isVoiceDeck && !isInSelectedVoiceDeck) {
                                    return;
                                  }
                                  if (isInSelectedVoiceDeck) {
                                    await _leaveSelectedVoiceDeck();
                                  } else {
                                    await _joinSelectedVoiceDeck();
                                  }
                                },
                                onToggleMic: () async {
                                  await _setSelectedMicMuted(
                                    !widget.appState.selectedMicMuted,
                                  );
                                },
                                onToggleAudio: () async {
                                  await _setSelectedAudioMuted(
                                    !widget.appState.selectedAudioMuted,
                                  );
                                },
                                onToggleCamera: () async {
                                  if (!isInSelectedVoiceDeck) return;
                                  await _setSelectedCameraEnabled(
                                    !widget.appState.selectedCameraEnabled,
                                  );
                                },
                                onToggleScreenShare: () async {
                                  if (!isInSelectedVoiceDeck) return;
                                  await _setSelectedScreenShareEnabled(
                                    !widget.appState.selectedScreenShareEnabled,
                                  );
                                },
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: -6,
                            bottom: 0,
                            width: 12,
                            child: _EdgeResizeHandle(
                              onDrag: (delta) {
                                setState(() {
                                  _channelSidebarWidth =
                                      (_channelSidebarWidth + delta)
                                          .clamp(minChannelSidebarWidth, 360.0);
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: ChatArea(
                              channel: selectedChannel,
                              messages: widget.appState.selectedMessages,
                              members: widget.appState.selectedMembers,
                              voiceMembers: isVoiceDeck
                                  ? widget.appState.membersForVoiceDeck(
                                      selectedChannel.id,
                                    )
                                  : const [],
                              voiceDeckState: isVoiceDeck
                                  ? widget.appState.voiceDeckStateForChannel(
                                      selectedChannel.id,
                                    )
                                  : null,
                              isInSelectedVoiceDeck: isInSelectedVoiceDeck,
                              isBusy: widget.appState.isBusy,
                              micMuted: widget.appState.selectedMicMuted,
                              audioMuted: widget.appState.selectedAudioMuted,
                              cameraEnabled:
                                  widget.appState.selectedCameraEnabled,
                              screenShareEnabled:
                                  widget.appState.selectedScreenShareEnabled,
                              speaking: widget.appState.selectedSpeaking,
                              micPermissionGranted:
                                  widget.appState.micPermissionGranted,
                              micCaptureActive:
                                  widget.appState.micCaptureActive,
                              micInputLevel: widget.appState.micInputLevel,
                              micInputPeak: widget.appState.micInputPeak,
                              micInputError: widget.appState.micInputError,
                              voiceTransportInitialized:
                                  widget.appState.voiceTransportInitialized,
                              voiceTransportJoining:
                                  widget.appState.voiceTransportJoining,
                              voiceTransportJoined:
                                  widget.appState.voiceTransportJoined,
                              voiceTransportMicrophoneReady: widget
                                  .appState.voiceTransportMicrophoneReady,
                              voiceTransportRemoteAudioAttached: widget
                                  .appState.voiceTransportRemoteAudioAttached,
                              voiceTransportLocalPeerId: widget
                                  .appState.voiceTransportSnapshot.localPeerId,
                              voiceTransportChannelId: widget
                                  .appState.voiceTransportSnapshot.voiceChannelId,
                              voiceTransportError:
                                  widget.appState.voiceTransportError,
                              voiceTransportPeers:
                                  widget.appState.voiceTransportPeers,
                              currentUserId:
                                  widget.appState.currentUserIdForSelectedServer,
                              voiceMemberVolumeForUserId:
                                  widget.appState.voiceMemberVolumeFor,
                              onSetVoiceMemberVolume: (userId, volume) {
                                return widget.appState.setVoiceMemberVolume(
                                  userId: userId,
                                  volume: volume,
                                );
                              },
                              localCameraTrack:
                                  widget.appState.localCameraTrack,
                              localScreenShareTrack:
                                  widget.appState.selectedScreenShareEnabled
                                      ? widget.appState.localScreenShareTrack
                                      : null,
                              remoteCameraTracks:
                                  widget.appState.remoteCameraTracks,
                              remoteScreenShareTracks:
                                  widget.appState.remoteScreenShareTracks,
                              onJoinVoiceDeck:
                                  isVoiceDeck ? _joinSelectedVoiceDeck : null,
                              onLeaveVoiceDeck:
                                  _leaveSelectedVoiceDeck,
                              onSetMicMuted: _setSelectedMicMuted,
                              onSetAudioMuted: _setSelectedAudioMuted,
                              onSetCameraEnabled:
                                  _setSelectedCameraEnabled,
                              onSetScreenShareEnabled:
                                  _setSelectedScreenShareEnabled,
                              onSetSpeaking: _setSelectedSpeaking,
                              onSend: (content) {
                                widget.appState.sendMessage(content);
                              },
                              onSendWithAttachments:
                                  (content, attachmentIds) async {
                                await widget.appState.sendMessage(
                                  content,
                                  attachmentIds: attachmentIds,
                                );
                              },
                              onUploadAttachment: (file) {
                                return widget.appState
                                    .uploadAttachmentFile(file);
                              },
                              onEditMessage: (message, content) {
                                return widget.appState.editMessage(message, content);
                              },
                              onDeleteMessage: (message) {
                                return widget.appState.deleteMessage(message);
                              },
                              canDeleteAnyMessage: widget.appState.isSelectedServerOwner,
                              onLoadLinkPreview:
                                  widget.appState.fetchLinkPreviewForSelectedServer,
                            ),
                          ),
                          SizedBox(
                            width: rightWidth,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: MemberSidebar(
                                    members: widget.appState.selectedMembers,
                                  ),
                                ),
                                Positioned(
                                  top: 0,
                                  left: -6,
                                  bottom: 0,
                                  width: 12,
                                  child: _EdgeResizeHandle(
                                    onDrag: (delta) {
                                      setState(() {
                                        _memberSidebarWidth =
                                            (_memberSidebarWidth - delta)
                                                .clamp(minMemberSidebarWidth, 360.0);
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const _EdgeResizeHandle({
    required this.onDrag,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) {
          onDrag(details.delta.dx);
        },
        child: Container(color: Colors.transparent),
      ),
    );
  }
}

class _HomeAndServerRail extends StatelessWidget {
  final List<ChatServer> servers;
  final String selectedServerId;
  final VoidCallback onGoHome;
  final ValueChanged<String> onServerSelected;
  final VoidCallback onAddServer;

  const _HomeAndServerRail({
    required this.servers,
    required this.selectedServerId,
    required this.onGoHome,
    required this.onServerSelected,
    required this.onAddServer,
  });

  String? _resolvedAssetUrl(ChatServer server) {
    final rawUrl = server.iconUrl;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }

    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }

    if (server.address.isEmpty) {
      return trimmed;
    }

    if (trimmed.startsWith('/')) {
      return '${server.address}$trimmed';
    }

    return '${server.address}/$trimmed';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        border: Border(
          right: BorderSide(color: NewChatColors.outline),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 18),
          _RailIconButton(
            tooltip: 'Home',
            selected: false,
            cornerRadius: 22,
            onTap: onGoHome,
            child: const Icon(Icons.home_rounded, size: 28),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: servers.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final server = servers[index];
                final selected = server.id == selectedServerId;

                return _RailIconButton(
                  tooltip: server.name,
                  selected: selected,
                  cornerRadius: 10,
                  onTap: () => onServerSelected(server.id),
                  imageUrl: _resolvedAssetUrl(server),
                  fallbackText: server.shortName,
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _RailIconButton(
            tooltip: 'Add node',
            selected: false,
            cornerRadius: 18,
            onTap: onAddServer,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class _RailIconButton extends StatelessWidget {
  final Widget? child;
  final VoidCallback onTap;
  final bool selected;
  final String tooltip;
  final double cornerRadius;
  final String? imageUrl;
  final String? fallbackText;

  const _RailIconButton({
    this.child,
    required this.onTap,
    required this.selected,
    required this.tooltip,
    required this.cornerRadius,
    this.imageUrl,
    this.fallbackText,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor =
        selected ? NewChatColors.accent : NewChatColors.surface;
    final borderColor =
        selected ? NewChatColors.accentGlow : NewChatColors.outline;

    Widget content;
    if (child != null) {
      content = child!;
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(cornerRadius - 1),
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          width: 56,
          height: 56,
          errorBuilder: (context, error, stackTrace) {
            return Center(
              child: Text(
                fallbackText ?? '?',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                  letterSpacing: -0.4,
                ),
              ),
            );
          },
        ),
      );
    } else {
      content = Center(
        child: Text(
          fallbackText ?? '?',
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 22,
            letterSpacing: -0.4,
          ),
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(cornerRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(cornerRadius),
            border: Border.all(color: borderColor),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x402B050B),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: content,
        ),
      ),
    );
  }
}

class _TopFrameBar extends StatelessWidget {
  final AppState appState;
  final VoidCallback onOpenUserSettings;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenAdminPanel;

  const _TopFrameBar({
    required this.appState,
    required this.onOpenUserSettings,
    required this.onOpenSettings,
    required this.onOpenAdminPanel,
  });

  Widget _iconAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: NewChatColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: NewChatColors.outline),
          ),
          child: Icon(
            icon,
            size: 20,
            color: NewChatColors.textMuted,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        border: Border(
          bottom: BorderSide(color: NewChatColors.outline),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            height: 45,
            child: Image.asset(
              'assets/branding/yappa_logo.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ),
          const SizedBox(width: 16),
          InkWell(
            onTap: onOpenUserSettings,
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: NewChatColors.surface,
                borderRadius: BorderRadius.circular(14),
                ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FrameBarAvatar(member: appState.currentUserMemberForSelectedServer),
                  const SizedBox(width: 8),
                  Text(appState.currentDisplayName),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _iconAction(
            tooltip: 'Settings',
            icon: Icons.settings_rounded,
            onTap: onOpenSettings,
          ),
          if (onOpenAdminPanel != null) ...[
            const SizedBox(width: 10),
            _iconAction(
              tooltip: 'Admin Panel',
              icon: Icons.admin_panel_settings_rounded,
              onTap: onOpenAdminPanel!,
            ),
          ],
          const Spacer(),
          if (appState.lastError != null && appState.lastError!.isNotEmpty) ...[
            Flexible(
              child: Text(
                appState.lastError!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFFB4BF)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FrameBarAvatar extends StatelessWidget {
  final Member? member;

  const _FrameBarAvatar({required this.member});

  @override
  Widget build(BuildContext context) {
    final displayName = member?.name ?? '';
    final initial = (displayName.isNotEmpty ? displayName.characters.first : '?').toUpperCase();
    final avatarSource = member?.avatarUrl;

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: NewChatColors.panelAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: _AvatarImage(
        source: avatarSource,
        fallbackInitial: initial,
        size: 24,
        fontSize: 11,
      ),
    );
  }
}

class _AvatarImage extends StatelessWidget {
  final String? source;
  final String fallbackInitial;
  final double size;
  final double fontSize;

  const _AvatarImage({
    required this.source,
    required this.fallbackInitial,
    required this.size,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return AvatarImage(
      source: source,
      fallbackInitial: fallbackInitial,
      size: size,
      animate: true,
    );
  }
}

class _SidebarVoiceControlDock extends StatelessWidget {
  final bool canJoinSelectedChannel;
  final bool isInSelectedVoiceDeck;
  final bool isBusy;
  final bool micMuted;
  final bool audioMuted;
  final bool cameraEnabled;
  final bool screenShareEnabled;
  final Future<void> Function()? onJoinLeave;
  final Future<void> Function()? onToggleMic;
  final Future<void> Function()? onToggleAudio;
  final Future<void> Function()? onToggleCamera;
  final Future<void> Function()? onToggleScreenShare;

  const _SidebarVoiceControlDock({
    required this.canJoinSelectedChannel,
    required this.isInSelectedVoiceDeck,
    required this.isBusy,
    required this.micMuted,
    required this.audioMuted,
    required this.cameraEnabled,
    required this.screenShareEnabled,
    this.onJoinLeave,
    this.onToggleMic,
    this.onToggleAudio,
    this.onToggleCamera,
    this.onToggleScreenShare,
  });

  @override
  Widget build(BuildContext context) {
    final canPressJoinLeave = isInSelectedVoiceDeck || canJoinSelectedChannel;

    return SizedBox(
      width: double.infinity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: NewChatColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: NewChatColors.outline),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 14,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: _SidebarVoiceControlButton(
                tooltip: isInSelectedVoiceDeck
                    ? 'Leave call'
                    : canJoinSelectedChannel
                        ? 'Join call'
                        : 'Select a voice deck to join',
                icon: isInSelectedVoiceDeck
                    ? Icons.call_end_rounded
                    : Icons.call_rounded,
                color: isInSelectedVoiceDeck
                    ? const Color(0xFFFF667E)
                    : canPressJoinLeave
                        ? const Color(0xFF54D17A)
                        : NewChatColors.textMuted,
                onTap: (isBusy || !canPressJoinLeave) ? null : onJoinLeave,
              ),
            ),
            const _SidebarVoiceControlDivider(),
            Expanded(
              child: _SidebarVoiceControlButton(
                tooltip: micMuted ? 'Unmute microphone' : 'Mute microphone',
                icon: micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                color: micMuted
                    ? const Color(0xFFFF667E)
                    : NewChatColors.textMuted,
                onTap: onToggleMic,
              ),
            ),
            const _SidebarVoiceControlDivider(),
            Expanded(
              child: _SidebarVoiceControlButton(
                tooltip: audioMuted ? 'Unmute audio' : 'Mute audio',
                icon: audioMuted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                color: audioMuted
                    ? const Color(0xFFFF667E)
                    : NewChatColors.textMuted,
                onTap: onToggleAudio,
              ),
            ),
            const _SidebarVoiceControlDivider(),
            Expanded(
              child: _SidebarVoiceControlButton(
                tooltip: cameraEnabled ? 'Turn camera off' : 'Turn camera on',
                icon: cameraEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                color: cameraEnabled
                    ? const Color(0xFF54D17A)
                    : NewChatColors.textMuted,
                onTap: isInSelectedVoiceDeck ? onToggleCamera : null,
              ),
            ),
            const _SidebarVoiceControlDivider(),
            Expanded(
              child: _SidebarVoiceControlButton(
                tooltip: screenShareEnabled
                    ? 'Stop screen share'
                    : 'Start screen share',
                icon: Icons.screen_share_rounded,
                color: screenShareEnabled
                    ? const Color(0xFF54D17A)
                    : NewChatColors.textMuted,
                onTap: isInSelectedVoiceDeck ? onToggleScreenShare : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarVoiceControlButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final Future<void> Function()? onTap;

  const _SidebarVoiceControlButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!.call(),
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          opacity: enabled ? 1 : 0.38,
          child: SizedBox(
            height: 38,
            child: Center(
              child: Icon(
                icon,
                size: 19,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarVoiceControlDivider extends StatelessWidget {
  const _SidebarVoiceControlDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      color: NewChatColors.outline,
      margin: const EdgeInsets.symmetric(horizontal: 2),
    );
  }
}
