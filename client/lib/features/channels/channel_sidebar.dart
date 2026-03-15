import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/channel_model.dart';
import '../../models/member_model.dart';
import '../../models/server_model.dart';
import '../../models/voice_models.dart';
import '../../shared/avatar_image.dart';

class ChannelSidebar extends StatefulWidget {
  final ChatServer server;
  final List<ChatChannel> channels;
  final List<Member> members;
  final List<VoiceDeckState> voiceDeckStates;
  final String selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final bool canOpenAdminPanel;
  final VoidCallback? onOpenAdminPanel;
  final Future<void> Function(String channelId)? onVoiceDeckDoubleTap;
  final String? currentUserId;
  final double Function(String userId)? voiceMemberVolumeForUserId;
  final Future<void> Function(String userId, double volume)? onSetVoiceMemberVolume;
  final Widget? bottomDock;

  const ChannelSidebar({
    super.key,
    required this.server,
    required this.channels,
    required this.members,
    required this.voiceDeckStates,
    required this.selectedChannelId,
    required this.onChannelSelected,
    this.canOpenAdminPanel = false,
    this.onOpenAdminPanel,
    this.onVoiceDeckDoubleTap,
    this.currentUserId,
    this.voiceMemberVolumeForUserId,
    this.onSetVoiceMemberVolume,
    this.bottomDock,
  });

  @override
  State<ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends State<ChannelSidebar> {
  Timer? _ticker;
  DateTime _now = DateTime.now();
  String? _lastTappedVoiceDeckId;
  DateTime? _lastTappedVoiceDeckAt;

  final Map<String, String> _channelGlyphById = <String, String>{};
  final Map<String, String> _channelNameOverrideById = <String, String>{};
  final Set<String> _mutedChannelIds = <String>{};
  final Map<String, _ChannelNotificationSettings> _notificationSettingsById =
      <String, _ChannelNotificationSettings>{};

  static const Duration _doubleTapWindow = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ChannelSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final shouldTick =
        widget.voiceDeckStates.any((deck) => deck.activeSince != null);

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
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    }
  }

  String? _resolvedAssetUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }

    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('data:image/')) {
      return trimmed;
    }

    if (widget.server.address.isEmpty) {
      return trimmed;
    }

    if (trimmed.startsWith('/')) {
      return '${widget.server.address}$trimmed';
    }

    return '${widget.server.address}/$trimmed';
  }

  VoiceDeckState? _voiceStateForChannel(String channelId) {
    for (final state in widget.voiceDeckStates) {
      if (state.channelId == channelId) {
        return state;
      }
    }
    return null;
  }

  List<Member> _membersForVoiceDeck(String channelId) {
    final members = widget.members
        .where((member) => member.voiceChannelId == channelId)
        .toList()
      ..sort((a, b) {
        if (a.isOwner != b.isOwner) {
          return a.isOwner ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return members;
  }

  String _formatElapsed(DateTime? since) {
    if (since == null) {
      return 'Idle';
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

  String _channelLabel(ChatChannel channel) {
    final override = _channelNameOverrideById[channel.id]?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return channel.name;
  }

  bool _isMuted(ChatChannel channel) => _mutedChannelIds.contains(channel.id);

  _ChannelNotificationSettings _notificationSettingsFor(String channelId) {
    return _notificationSettingsById[channelId] ??
        const _ChannelNotificationSettings();
  }

  double _voiceMemberVolumeFor(String userId) {
    return widget.voiceMemberVolumeForUserId?.call(userId) ?? 1.0;
  }

  String _formatVoiceMemberVolumeLabel(double volume) {
    return '${(volume * 100).round()}%';
  }

  Future<void> _showVoiceMemberContextMenu({
    required TapDownDetails details,
    required Member member,
  }) async {
    if (member.id == widget.currentUserId) {
      return;
    }

    final callback = widget.onSetVoiceMemberVolume;
    if (callback == null) {
      return;
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final currentVolume = _voiceMemberVolumeFor(member.id);

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
            '${member.name} • ${_formatVoiceMemberVolumeLabel(currentVolume)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<double>(
          value: 0.0,
          child: Text('Mute • 0%'),
        ),
        const PopupMenuItem<double>(
          value: 0.25,
          child: Text('Very quiet • 25%'),
        ),
        const PopupMenuItem<double>(
          value: 0.5,
          child: Text('Half volume • 50%'),
        ),
        const PopupMenuItem<double>(
          value: 0.75,
          child: Text('Lower volume • 75%'),
        ),
        const PopupMenuItem<double>(
          value: 1.0,
          child: Text('Normal • 100%'),
        ),
        const PopupMenuItem<double>(
          value: 1.25,
          child: Text('Boost • 125%'),
        ),
        const PopupMenuItem<double>(
          value: 1.5,
          child: Text('Boost more • 150%'),
        ),
      ],
    );

    if (selected == null) {
      return;
    }

    await callback(member.id, selected);
    if (!mounted) {
      return;
    }

    _showInfoSnack(
      '${member.name} volume set to ${_formatVoiceMemberVolumeLabel(selected)} for you.',
    );
  }

  Future<void> _handleVoiceDeckTap(String channelId) async {
    widget.onChannelSelected(channelId);

    final callback = widget.onVoiceDeckDoubleTap;
    if (callback == null) return;

    final now = DateTime.now();
    final isSecondTap =
        _lastTappedVoiceDeckId == channelId &&
        _lastTappedVoiceDeckAt != null &&
        now.difference(_lastTappedVoiceDeckAt!) <= _doubleTapWindow;

    _lastTappedVoiceDeckId = channelId;
    _lastTappedVoiceDeckAt = now;

    if (isSecondTap) {
      _lastTappedVoiceDeckId = null;
      _lastTappedVoiceDeckAt = null;
      await callback(channelId);
    }
  }

  Future<void> _showBlankAreaMenu(TapDownDetails details) async {
    if (!widget.canOpenAdminPanel) {
      return;
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_BlankAreaAction>(
      context: context,
      color: NewChatColors.panel,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          details.globalPosition,
          details.globalPosition,
        ),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<_BlankAreaAction>(
          value: _BlankAreaAction.createChannel,
          child: Text('Create Channel'),
        ),
        PopupMenuItem<_BlankAreaAction>(
          value: _BlankAreaAction.createCategory,
          child: Text('Create Category'),
        ),
      ],
    );

    switch (selected) {
      case _BlankAreaAction.createChannel:
        _showCreatePlaceholderDialog();
        break;
      case _BlankAreaAction.createCategory:
        _showInfoSnack('Channel categories are menu-only for now.');
        break;
      case null:
        break;
    }
  }

  Future<void> _showChannelContextMenu({
    required TapDownDetails details,
    required ChatChannel channel,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isMuted = _isMuted(channel);

    final selected = await showMenu<_ChannelAction>(
      context: context,
      color: NewChatColors.panel,
      position: RelativeRect.fromRect(
        Rect.fromPoints(details.globalPosition, details.globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<_ChannelAction>(
          value: _ChannelAction.mute,
          child: Text(isMuted ? 'Mute Settings…' : 'Mute Channel…'),
        ),
        const PopupMenuItem<_ChannelAction>(
          value: _ChannelAction.notifications,
          child: Text('Notification Settings…'),
        ),
        if (widget.canOpenAdminPanel) const PopupMenuDivider(),
        if (widget.canOpenAdminPanel)
          const PopupMenuItem<_ChannelAction>(
            value: _ChannelAction.edit,
            child: Text('Edit Channel'),
          ),
        if (widget.canOpenAdminPanel)
          const PopupMenuItem<_ChannelAction>(
            value: _ChannelAction.duplicate,
            child: Text('Duplicate Channel'),
          ),
        if (widget.canOpenAdminPanel)
          const PopupMenuItem<_ChannelAction>(
            value: _ChannelAction.delete,
            child: Text('Delete Channel'),
          ),
      ],
    );

    switch (selected) {
      case _ChannelAction.mute:
        _showMuteDialog(channel);
        break;
      case _ChannelAction.notifications:
        _showNotificationDialog(channel);
        break;
      case _ChannelAction.edit:
        _showEditChannelDialog(channel);
        break;
      case _ChannelAction.duplicate:
        _showInfoSnack('Duplicate Channel is menu-only for now.');
        break;
      case _ChannelAction.delete:
        _showInfoSnack('Delete Channel is menu-only for now.');
        break;
      case null:
        break;
    }
  }

  Future<void> _showCreatePlaceholderDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NewChatColors.panel,
        title: const Text('Create Channel'),
        content: Text(
          'This menu is in place. Live channel creation wiring can be added next.',
          style: TextStyle(color: NewChatColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showMuteDialog(ChatChannel channel) async {
    final initialMuted = _isMuted(channel);
    String mode = initialMuted ? 'forever' : 'hour';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: Text('Mute ${_channelLabel(channel)}'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose how long this channel should stay muted locally.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _ChoiceChipButton(
                          label: '1 hour',
                          selected: mode == 'hour',
                          onTap: () => setStateDialog(() => mode = 'hour'),
                        ),
                        _ChoiceChipButton(
                          label: '1 day',
                          selected: mode == 'day',
                          onTap: () => setStateDialog(() => mode = 'day'),
                        ),
                        _ChoiceChipButton(
                          label: 'Forever',
                          selected: mode == 'forever',
                          onTap: () => setStateDialog(() => mode = 'forever'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      initialMuted
                          ? 'This channel is currently muted.'
                          : 'This channel is currently unmuted.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                  ],
                ),
              ),
              actions: [
                if (initialMuted)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _mutedChannelIds.remove(channel.id);
                      });
                      Navigator.of(context).pop();
                    },
                    child: const Text('Unmute'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _mutedChannelIds.add(channel.id);
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showNotificationDialog(ChatChannel channel) async {
    var current = _notificationSettingsFor(channel.id);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: Text('Notification Settings • ${_channelLabel(channel)}'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      value: current.mentions,
                      onChanged: (value) {
                        setStateDialog(() {
                          current = current.copyWith(mentions: value ?? false);
                        });
                      },
                      title: const Text('@mentions'),
                      activeColor: NewChatColors.accentGlow,
                      contentPadding: EdgeInsets.zero,
                    ),
                    CheckboxListTile(
                      value: current.everyone,
                      onChanged: (value) {
                        setStateDialog(() {
                          current = current.copyWith(everyone: value ?? false);
                        });
                      },
                      title: const Text('@everyone'),
                      activeColor: NewChatColors.accentGlow,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _notificationSettingsById[channel.id] = current;
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showEditChannelDialog(ChatChannel channel) async {
    final controller = TextEditingController(text: _channelLabel(channel));
    var selectedGlyph = _channelGlyphById[channel.id];

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: Text('Edit Channel • ${channel.name}'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        labelText: 'Channel name',
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Icon or Emoji',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _ChannelGlyphPreview(
                          channel: channel,
                          glyph: selectedGlyph,
                          selected: true,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            selectedGlyph == null
                                ? 'Using the default channel icon.'
                                : 'Custom picker selection applied.',
                            style: TextStyle(color: NewChatColors.textMuted),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final picked = await _showChannelGlyphPicker(
                              context,
                              initialValue: selectedGlyph,
                              channelType: channel.type,
                            );
                            if (!mounted) return;
                            if (picked != null) {
                              setStateDialog(() {
                                selectedGlyph = picked;
                              });
                            }
                          },
                          icon: const Icon(Icons.emoji_emotions_outlined),
                          label: const Text('Choose Icon / Emoji'),
                        ),
                        OutlinedButton.icon(
                          onPressed: selectedGlyph == null
                              ? null
                              : () {
                                  setStateDialog(() {
                                    selectedGlyph = null;
                                  });
                                },
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Clear'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _channelNameOverrideById[channel.id] =
                          controller.text.trim().isEmpty
                              ? channel.name
                              : controller.text.trim();

                      if (selectedGlyph == null || selectedGlyph!.isEmpty) {
                        _channelGlyphById.remove(channel.id);
                      } else {
                        _channelGlyphById[channel.id] = selectedGlyph!;
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _showChannelGlyphPicker(
    BuildContext context, {
    required ChannelType channelType,
    String? initialValue,
  }) async {
    _GlyphTab activeTab = initialValue != null && initialValue.startsWith('emoji:')
        ? _GlyphTab.emojis
        : _GlyphTab.icons;
    String? pendingValue = initialValue;

    return showDialog<String?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final iconOptions = channelType == ChannelType.voice
                ? _voiceIconOptions
                : _textIconOptions;

            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: const Text('Pick Channel Icon or Emoji'),
              content: SizedBox(
                width: 560,
                height: 500,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _ChoiceChipButton(
                          label: 'Icons',
                          selected: activeTab == _GlyphTab.icons,
                          onTap: () => setStateDialog(() {
                            activeTab = _GlyphTab.icons;
                          }),
                        ),
                        _ChoiceChipButton(
                          label: 'Emojis',
                          selected: activeTab == _GlyphTab.emojis,
                          onTap: () => setStateDialog(() {
                            activeTab = _GlyphTab.emojis;
                          }),
                        ),
                        if (pendingValue != null)
                          OutlinedButton.icon(
                            onPressed: () => setStateDialog(() {
                              pendingValue = null;
                            }),
                            icon: const Icon(Icons.clear_rounded),
                            label: const Text('Clear selection'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      activeTab == _GlyphTab.icons
                          ? 'Choose from a channel-friendly icon set.'
                          : 'Choose from the full emoji list below.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121924),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: NewChatColors.outline),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: activeTab == _GlyphTab.icons
                              ? GridView.builder(
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 5,
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 1.2,
                                  ),
                                  itemCount: iconOptions.length,
                                  itemBuilder: (context, index) {
                                    final option = iconOptions[index];
                                    final value = 'icon:${option.keyName}';
                                    final isSelected = pendingValue == value;
                                    return _GlyphGridButton(
                                      selected: isSelected,
                                      onTap: () => setStateDialog(() {
                                        pendingValue = value;
                                      }),
                                      child: Icon(
                                        option.icon,
                                        size: 22,
                                        color: isSelected
                                            ? Colors.white
                                            : NewChatColors.textMuted,
                                      ),
                                    );
                                  },
                                )
                              : GridView.builder(
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 7,
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 1.08,
                                  ),
                                  itemCount: _emojiOptions.length,
                                  itemBuilder: (context, index) {
                                    final emoji = _emojiOptions[index];
                                    final value = 'emoji:$emoji';
                                    final isSelected = pendingValue == value;
                                    return _GlyphGridButton(
                                      selected: isSelected,
                                      onTap: () => setStateDialog(() {
                                        pendingValue = value;
                                      }),
                                      child: Center(
                                        child: Text(
                                          emoji,
                                          style: const TextStyle(fontSize: 22),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(pendingValue),
                  child: const Text('Use Selection'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showInfoSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bannerUrl = _resolvedAssetUrl(widget.server.bannerUrl);

    final textChannels = widget.channels
        .where((channel) => channel.type == ChannelType.text)
        .toList();
    final voiceChannels = widget.channels
        .where((channel) => channel.type == ChannelType.voice)
        .toList();

    return Container(
      color: NewChatColors.panelAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ServerHeader(
            server: widget.server,
            bannerUrl: bannerUrl,
          ),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      const _SectionLabel(label: 'TEXT FEEDS'),
                      for (final channel in textChannels)
                        _ChannelTile(
                          channel: channel,
                          displayName: _channelLabel(channel),
                          glyph: _channelGlyphById[channel.id],
                          selected: channel.id == widget.selectedChannelId,
                          muted: _isMuted(channel),
                          onTap: () => widget.onChannelSelected(channel.id),
                          onSecondaryTapDown: (details) {
                            _showChannelContextMenu(
                              details: details,
                              channel: channel,
                            );
                          },
                        ),
                      const SizedBox(height: 12),
                      const _SectionLabel(label: 'VOICE DECKS'),
                      for (final channel in voiceChannels)
                        _VoiceDeckTile(
                          channel: channel,
                          displayName: _channelLabel(channel),
                          glyph: _channelGlyphById[channel.id],
                          selected: channel.id == widget.selectedChannelId,
                          muted: _isMuted(channel),
                          onTap: () => _handleVoiceDeckTap(channel.id),
                          onSecondaryTapDown: (details) {
                            _showChannelContextMenu(
                              details: details,
                              channel: channel,
                            );
                          },
                          state: _voiceStateForChannel(channel.id),
                          members: _membersForVoiceDeck(channel.id),
                          elapsedLabel: _formatElapsed(
                            _voiceStateForChannel(channel.id)?.activeSince,
                          ),
                          currentUserId: widget.currentUserId,
                          voiceMemberVolumeForUserId: _voiceMemberVolumeFor,
                          onVoiceMemberSecondaryTapDown: (member, details) =>
                              _showVoiceMemberContextMenu(
                                details: details,
                                member: member,
                              ),
                          resolveAvatarUrl: _resolvedAssetUrl,
                        ),
                      if (widget.canOpenAdminPanel)
                        const SizedBox(height: 18),
                      if (widget.canOpenAdminPanel)
                        _BlankAreaContextTarget(
                          onSecondaryTapDown: _showBlankAreaMenu,
                        ),
                    ],
                  ),
                ),
                if (widget.bottomDock != null) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                    child: widget.bottomDock!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BlankAreaContextTarget extends StatelessWidget {
  final ValueChanged<TapDownDetails> onSecondaryTapDown;

  const _BlankAreaContextTarget({
    required this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: onSecondaryTapDown,
        child: Container(
          height: 160,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: NewChatColors.outline.withValues(alpha: 0.18),
            ),
            color: Colors.transparent,
          ),
          child: Center(
            child: Text(
              'Right click to create a channel or category',
              style: TextStyle(
                color: NewChatColors.textMuted.withValues(alpha: 0.72),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerHeader extends StatelessWidget {
  final ChatServer server;
  final String? bannerUrl;

  const _ServerHeader({
    required this.server,
    required this.bannerUrl,
  });

  @override
  Widget build(BuildContext context) {
    final hasBanner = bannerUrl != null && bannerUrl!.isNotEmpty;
    final tagline = server.tagline.trim();

    return SizedBox(
      height: 106,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: NewChatColors.outline),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasBanner)
              ClipRect(
                child: Image.network(
                  bannerUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(color: NewChatColors.panel);
                  },
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: hasBanner
                      ? const [
                          Color(0x26000000),
                          Color(0x9A090B0E),
                          Color(0xFF0E1013),
                        ]
                      : [
                          NewChatColors.panelAlt,
                          NewChatColors.panel,
                        ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (tagline.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              tagline,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: hasBanner
                                    ? Colors.white.withValues(alpha: 0.84)
                                    : NewChatColors.textMuted,
                                fontSize: 12,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Text(
        label,
        style: TextStyle(
          color: NewChatColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

class _ChannelTile extends StatefulWidget {
  final ChatChannel channel;
  final String displayName;
  final String? glyph;
  final bool selected;
  final bool muted;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;

  const _ChannelTile({
    required this.channel,
    required this.displayName,
    required this.glyph,
    required this.selected,
    required this.muted,
    required this.onTap,
    required this.onSecondaryTapDown,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.selected
        ? const Color(0xFF23151B)
        : const Color(0xFF202837).withValues(alpha: _hovering ? 0.72 : 0.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: hoverColor,
                border: Border.all(
                  color: widget.selected
                      ? NewChatColors.accentGlow
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  _ChannelGlyphPreview(
                    channel: widget.channel,
                    glyph: widget.glyph,
                    selected: widget.selected,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.displayName,
                      style: TextStyle(
                        fontWeight:
                            widget.selected ? FontWeight.w800 : FontWeight.w600,
                        color: widget.selected
                            ? Colors.white
                            : NewChatColors.textMuted,
                      ),
                    ),
                  ),
                  if (widget.muted)
                    Icon(
                      Icons.volume_off_rounded,
                      size: 15,
                      color: NewChatColors.textMuted,
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

class _VoiceDeckTile extends StatefulWidget {
  final ChatChannel channel;
  final String displayName;
  final String? glyph;
  final VoiceDeckState? state;
  final List<Member> members;
  final bool selected;
  final bool muted;
  final String elapsedLabel;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;
  final String? currentUserId;
  final double Function(String userId)? voiceMemberVolumeForUserId;
  final Future<void> Function(Member member, TapDownDetails details)?
      onVoiceMemberSecondaryTapDown;
  final String? Function(String? rawUrl) resolveAvatarUrl;

  const _VoiceDeckTile({
    required this.channel,
    required this.displayName,
    required this.glyph,
    required this.state,
    required this.members,
    required this.selected,
    required this.muted,
    required this.elapsedLabel,
    required this.onTap,
    required this.onSecondaryTapDown,
    required this.currentUserId,
    required this.voiceMemberVolumeForUserId,
    required this.onVoiceMemberSecondaryTapDown,
    required this.resolveAvatarUrl,
  });

  @override
  State<_VoiceDeckTile> createState() => _VoiceDeckTileState();
}

class _VoiceDeckTileState extends State<_VoiceDeckTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final occupancy = widget.state?.occupancy ?? widget.members.length;
    final hasActiveDeck = occupancy > 0 || widget.state?.activeSince != null;
    final showMembers = widget.members.isNotEmpty;

    final hoverColor = widget.selected
        ? const Color(0xFF23151B)
        : const Color(0xFF202837).withValues(alpha: _hovering ? 0.72 : 0.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: hoverColor,
              border: Border.all(
                color: widget.selected
                    ? NewChatColors.accentGlow
                    : Colors.transparent,
              ),
            ),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _ChannelGlyphPreview(
                          channel: widget.channel,
                          glyph: widget.glyph,
                          selected: widget.selected,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.displayName,
                            style: TextStyle(
                              fontWeight: widget.selected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: widget.selected
                                  ? Colors.white
                                  : NewChatColors.textMuted,
                            ),
                          ),
                        ),
                        if (hasActiveDeck) ...[
                          Icon(
                            Icons.timer_outlined,
                            size: 13,
                            color: NewChatColors.accentGlow,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            widget.elapsedLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF18202E),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: NewChatColors.outline),
                            ),
                            child: Text(
                              '$occupancy',
                              style: TextStyle(
                                color: widget.selected
                                    ? Colors.white
                                    : NewChatColors.textMuted,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                        if (widget.muted) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.volume_off_rounded,
                            size: 15,
                            color: NewChatColors.textMuted,
                          ),
                        ],
                      ],
                    ),
                    if (showMembers) ...[
                      const SizedBox(height: 10),
                      Column(
                        children: [
                          for (final member in widget.members)
                            Builder(
                              builder: (context) {
                                final memberVolume =
                                    widget.voiceMemberVolumeForUserId?.call(
                                          member.id,
                                        ) ??
                                        1.0;
                                final canAdjustVolume =
                                    member.id != widget.currentUserId &&
                                    widget.onVoiceMemberSecondaryTapDown != null;

                                return MouseRegion(
                                  cursor: canAdjustVolume
                                      ? SystemMouseCursors.click
                                      : SystemMouseCursors.basic,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onSecondaryTapDown: canAdjustVolume
                                        ? (details) =>
                                            widget.onVoiceMemberSecondaryTapDown!(
                                              member,
                                              details,
                                            )
                                        : null,
                                    child: Container(
                                      margin: const EdgeInsets.only(top: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF131923),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: NewChatColors.outline,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Container(
                                                width: 26,
                                                height: 26,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF2D3547),
                                                  borderRadius:
                                                      BorderRadius.circular(9),
                                                ),
                                                clipBehavior: Clip.antiAlias,
                                                alignment: Alignment.center,
                                                child: AvatarImage(
                                                  source: widget.resolveAvatarUrl(
                                                    member.avatarUrl,
                                                  ),
                                                  fallbackInitial:
                                                      member.name.isNotEmpty
                                                          ? member.name[0]
                                                              .toUpperCase()
                                                          : '?',
                                                  size: 26,
                                                  animate: true,
                                                ),
                                              ),
                                              if (member.isOwner)
                                                Positioned(
                                                  left: -4,
                                                  top: -7,
                                                  child: Transform.rotate(
                                                    angle: -0.42,
                                                    alignment:
                                                        Alignment.bottomRight,
                                                    child: const Text(
                                                      '👑',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        height: 1,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              member.name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          if (canAdjustVolume &&
                                              (memberVolume - 1.0).abs() >= 0.001)
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF18202E),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                border: Border.all(
                                                  color: NewChatColors.outline,
                                                ),
                                              ),
                                              child: Text(
                                                '${(memberVolume * 100).round()}%',
                                                style: TextStyle(
                                                  color: NewChatColors.textMuted,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelGlyphPreview extends StatelessWidget {
  final ChatChannel channel;
  final String? glyph;
  final bool selected;

  const _ChannelGlyphPreview({
    required this.channel,
    required this.glyph,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = selected ? Colors.white : NewChatColors.textMuted;
    final parsed = _parseChannelGlyph(glyph);

    if (parsed is _EmojiGlyph) {
      return SizedBox(
        width: 18,
        height: 18,
        child: Center(
          child: Text(
            parsed.emoji,
            style: const TextStyle(fontSize: 16, height: 1),
          ),
        ),
      );
    }

    if (parsed is _IconGlyph) {
      return Icon(parsed.icon, size: 18, color: iconColor);
    }

    final fallbackIcon = channel.type == ChannelType.text
        ? Icons.notes_rounded
        : Icons.graphic_eq_rounded;
    return Icon(fallbackIcon, size: 18, color: iconColor);
  }
}

class _ChoiceChipButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF23151B) : const Color(0xFF18202E),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? NewChatColors.accentGlow : NewChatColors.outline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : NewChatColors.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphGridButton extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _GlyphGridButton({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF23151B) : const Color(0xFF18202E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? NewChatColors.accentGlow : NewChatColors.outline,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ChannelNotificationSettings {
  final bool mentions;
  final bool everyone;

  const _ChannelNotificationSettings({
    this.mentions = true,
    this.everyone = true,
  });

  _ChannelNotificationSettings copyWith({
    bool? mentions,
    bool? everyone,
  }) {
    return _ChannelNotificationSettings(
      mentions: mentions ?? this.mentions,
      everyone: everyone ?? this.everyone,
    );
  }
}

enum _BlankAreaAction {
  createChannel,
  createCategory,
}

enum _ChannelAction {
  mute,
  notifications,
  edit,
  duplicate,
  delete,
}

enum _GlyphTab { icons, emojis }

abstract class _ParsedGlyph {
  const _ParsedGlyph();
}

class _IconGlyph extends _ParsedGlyph {
  final IconData icon;
  const _IconGlyph(this.icon);
}

class _EmojiGlyph extends _ParsedGlyph {
  final String emoji;
  const _EmojiGlyph(this.emoji);
}

class _IconOption {
  final String keyName;
  final IconData icon;

  const _IconOption(this.keyName, this.icon);
}

_ParsedGlyph? _parseChannelGlyph(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }

  if (value.startsWith('emoji:')) {
    return _EmojiGlyph(value.substring(6));
  }

  if (value.startsWith('icon:')) {
    final key = value.substring(5);
    final icon = _iconLookup[key];
    if (icon != null) {
      return _IconGlyph(icon);
    }
  }

  return null;
}

const List<_IconOption> _textIconOptions = [
  _IconOption('notes_rounded', Icons.notes_rounded),
  _IconOption('tag_rounded', Icons.tag_rounded),
  _IconOption('alternate_email_rounded', Icons.alternate_email_rounded),
  _IconOption('forum_rounded', Icons.forum_rounded),
  _IconOption('article_rounded', Icons.article_rounded),
  _IconOption('announcement_rounded', Icons.campaign_rounded),
  _IconOption('terminal_rounded', Icons.terminal_rounded),
  _IconOption('code_rounded', Icons.code_rounded),
  _IconOption('palette_rounded', Icons.palette_rounded),
  _IconOption('sports_esports_rounded', Icons.sports_esports_rounded),
  _IconOption('image_rounded', Icons.image_rounded),
  _IconOption('movie_rounded', Icons.movie_rounded),
  _IconOption('music_note_rounded', Icons.music_note_rounded),
  _IconOption('camera_alt_rounded', Icons.camera_alt_rounded),
  _IconOption('rocket_launch_rounded', Icons.rocket_launch_rounded),
  _IconOption('bug_report_rounded', Icons.bug_report_rounded),
  _IconOption('shopping_bag_rounded', Icons.shopping_bag_rounded),
  _IconOption('school_rounded', Icons.school_rounded),
  _IconOption('event_rounded', Icons.event_rounded),
  _IconOption('shield_rounded', Icons.shield_rounded),
  _IconOption('inventory_2_rounded', Icons.inventory_2_rounded),
  _IconOption('lightbulb_rounded', Icons.lightbulb_rounded),
  _IconOption('place_rounded', Icons.place_rounded),
  _IconOption('build_rounded', Icons.build_rounded),
  _IconOption('auto_awesome_rounded', Icons.auto_awesome_rounded),
  _IconOption('favorite_rounded', Icons.favorite_rounded),
  _IconOption('star_rounded', Icons.star_rounded),
  _IconOption('explore_rounded', Icons.explore_rounded),
  _IconOption('flag_rounded', Icons.flag_rounded),
  _IconOption('description_rounded', Icons.description_rounded),
];

const List<_IconOption> _voiceIconOptions = [
  _IconOption('graphic_eq_rounded', Icons.graphic_eq_rounded),
  _IconOption('headset_mic_rounded', Icons.headset_mic_rounded),
  _IconOption('mic_rounded', Icons.mic_rounded),
  _IconOption('record_voice_over_rounded', Icons.record_voice_over_rounded),
  _IconOption('podcasts_rounded', Icons.podcasts_rounded),
  _IconOption('campaign_rounded', Icons.campaign_rounded),
  _IconOption('theaters_rounded', Icons.theaters_rounded),
  _IconOption('sports_esports_rounded', Icons.sports_esports_rounded),
  _IconOption('videocam_rounded', Icons.videocam_rounded),
  _IconOption('live_tv_rounded', Icons.live_tv_rounded),
  _IconOption('music_note_rounded', Icons.music_note_rounded),
  _IconOption('radio_rounded', Icons.radio_rounded),
  _IconOption('groups_rounded', Icons.groups_rounded),
  _IconOption('rocket_launch_rounded', Icons.rocket_launch_rounded),
  _IconOption('auto_awesome_rounded', Icons.auto_awesome_rounded),
];

const Map<String, IconData> _iconLookup = {
  'notes_rounded': Icons.notes_rounded,
  'tag_rounded': Icons.tag_rounded,
  'alternate_email_rounded': Icons.alternate_email_rounded,
  'forum_rounded': Icons.forum_rounded,
  'article_rounded': Icons.article_rounded,
  'announcement_rounded': Icons.campaign_rounded,
  'terminal_rounded': Icons.terminal_rounded,
  'code_rounded': Icons.code_rounded,
  'palette_rounded': Icons.palette_rounded,
  'sports_esports_rounded': Icons.sports_esports_rounded,
  'image_rounded': Icons.image_rounded,
  'movie_rounded': Icons.movie_rounded,
  'music_note_rounded': Icons.music_note_rounded,
  'camera_alt_rounded': Icons.camera_alt_rounded,
  'rocket_launch_rounded': Icons.rocket_launch_rounded,
  'bug_report_rounded': Icons.bug_report_rounded,
  'shopping_bag_rounded': Icons.shopping_bag_rounded,
  'school_rounded': Icons.school_rounded,
  'event_rounded': Icons.event_rounded,
  'shield_rounded': Icons.shield_rounded,
  'inventory_2_rounded': Icons.inventory_2_rounded,
  'lightbulb_rounded': Icons.lightbulb_rounded,
  'place_rounded': Icons.place_rounded,
  'build_rounded': Icons.build_rounded,
  'auto_awesome_rounded': Icons.auto_awesome_rounded,
  'favorite_rounded': Icons.favorite_rounded,
  'star_rounded': Icons.star_rounded,
  'explore_rounded': Icons.explore_rounded,
  'flag_rounded': Icons.flag_rounded,
  'description_rounded': Icons.description_rounded,
  'graphic_eq_rounded': Icons.graphic_eq_rounded,
  'headset_mic_rounded': Icons.headset_mic_rounded,
  'mic_rounded': Icons.mic_rounded,
  'record_voice_over_rounded': Icons.record_voice_over_rounded,
  'podcasts_rounded': Icons.podcasts_rounded,
  'campaign_rounded': Icons.campaign_rounded,
  'theaters_rounded': Icons.theaters_rounded,
  'videocam_rounded': Icons.videocam_rounded,
  'live_tv_rounded': Icons.live_tv_rounded,
  'radio_rounded': Icons.radio_rounded,
  'groups_rounded': Icons.groups_rounded,
};

const List<String> _emojiOptions = [
  '😀', '😁', '😂', '🤣', '😅', '😊', '😍', '🥳', '😎', '🤖', '👾', '🔥',
  '✨', '💫', '⭐', '🌙', '☀️', '⚡', '❄️', '🌈', '🎉', '🎊', '🎈', '🎵',
  '🎮', '🕹️', '🎬', '🎨', '🧠', '💡', '📢', '📸', '💬', '🛠️', '📌', '📎',
  '📚', '📅', '🧪', '🧰', '🛰️', '🚀', '🛡️', '🏆', '👑', '❤️', '🖤', '💙',
  '💚', '💜', '💛', '🧡', '🩷', '🐍', '🐉', '🦊', '🐺', '🐻', '🐸', '🐙',
  '🦈', '🦇', '🕷️', '🌹', '🍀', '🌵', '🌊', '🏴', '🎯', '🔒', '🔔', '🔕',
  '💣', '☕', '🍕', '🍜', '🍓', '🍄', '🌶️', '🧃', '🧊', '💀', '👻', '😈',
  '🤍', '🤝', '👏', '🙌', '🤌', '👌', '🫡', '🫶', '👍', '👎', '🫠', '🥶',
  '😴', '🤯', '🥲', '🫣', '😤', '🤠', '🛸', '🪐', '🌌', '🎤', '📻', '🎻',
];
