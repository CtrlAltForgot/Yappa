import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/channel_model.dart';
import '../../models/member_model.dart';
import '../../models/server_model.dart';
import '../../models/voice_models.dart';

class ChannelSidebar extends StatefulWidget {
  final ChatServer server;
  final List<ChatChannel> channels;
  final List<Member> members;
  final List<VoiceDeckState> voiceDeckStates;
  final String selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final bool canOpenAdminPanel;
  final VoidCallback? onOpenAdminPanel;

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
  });

  @override
  State<ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends State<ChannelSidebar> {
  final Set<String> _expandedVoiceDeckIds = <String>{};
  Timer? _ticker;
  DateTime _now = DateTime.now();

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
      setState(() {
        _now = DateTime.now();
      });
    }
  }

  String? _resolvedAssetUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }

    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
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
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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

  void _toggleVoiceDeckExpanded(String channelId) {
    setState(() {
      if (_expandedVoiceDeckIds.contains(channelId)) {
        _expandedVoiceDeckIds.remove(channelId);
      } else {
        _expandedVoiceDeckIds.add(channelId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final textChannels = widget.channels
        .where((channel) => channel.type == ChannelType.text)
        .toList();
    final voiceChannels = widget.channels
        .where((channel) => channel.type == ChannelType.voice)
        .toList();

    final bannerUrl = _resolvedAssetUrl(widget.server.bannerUrl);

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
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const _SectionLabel(label: 'TEXT FEEDS'),
                for (final channel in textChannels)
                  _ChannelTile(
                    channel: channel,
                    selected: channel.id == widget.selectedChannelId,
                    onTap: () => widget.onChannelSelected(channel.id),
                  ),
                const SizedBox(height: 12),
                const _SectionLabel(label: 'VOICE DECKS'),
                for (final channel in voiceChannels)
                  _VoiceDeckTile(
                    channel: channel,
                    selected: channel.id == widget.selectedChannelId,
                    onTap: () => widget.onChannelSelected(channel.id),
                    state: _voiceStateForChannel(channel.id),
                    members: _membersForVoiceDeck(channel.id),
                    isExpanded: _expandedVoiceDeckIds.contains(channel.id),
                    elapsedLabel: _formatElapsed(
                      _voiceStateForChannel(channel.id)?.activeSince,
                    ),
                    onToggleExpanded: () => _toggleVoiceDeckExpanded(channel.id),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
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
              padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  height: 74,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
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

class _ChannelTile extends StatelessWidget {
  final ChatChannel channel;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final icon = channel.type == ChannelType.text
        ? Icons.notes_rounded
        : Icons.graphic_eq_rounded;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: selected ? const Color(0xFF23151B) : Colors.transparent,
            border: Border.all(
              color: selected ? NewChatColors.accentGlow : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : NewChatColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  channel.name,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? Colors.white : NewChatColors.textMuted,
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

class _VoiceDeckTile extends StatelessWidget {
  final ChatChannel channel;
  final VoiceDeckState? state;
  final List<Member> members;
  final bool selected;
  final bool isExpanded;
  final String elapsedLabel;
  final VoidCallback onTap;
  final VoidCallback onToggleExpanded;

  const _VoiceDeckTile({
    required this.channel,
    required this.state,
    required this.members,
    required this.selected,
    required this.isExpanded,
    required this.elapsedLabel,
    required this.onTap,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final occupancy = state?.occupancy ?? members.length;
    final hasActiveDeck = occupancy > 0 || state?.activeSince != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: selected ? const Color(0xFF23151B) : Colors.transparent,
          border: Border.all(
            color: selected ? NewChatColors.accentGlow : Colors.transparent,
          ),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 18,
                      color: selected ? Colors.white : NewChatColors.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        channel.name,
                        style: TextStyle(
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          color:
                              selected ? Colors.white : NewChatColors.textMuted,
                        ),
                      ),
                    ),
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
                          color:
                              selected ? Colors.white : NewChatColors.textMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: onToggleExpanded,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          isExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: NewChatColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 13,
                    color: hasActiveDeck
                        ? NewChatColors.accentGlow
                        : NewChatColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    elapsedLabel,
                    style: TextStyle(
                      color: hasActiveDeck
                          ? Colors.white.withValues(alpha: 0.92)
                          : NewChatColors.textMuted,
                      fontSize: 12,
                      fontWeight: hasActiveDeck
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$occupancy members',
                    style: TextStyle(
                      color: NewChatColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: isExpanded && members.isNotEmpty
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: [
                    for (final member in members)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131923),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: NewChatColors.outline),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2D3547),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                member.name.isNotEmpty
                                    ? member.name[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
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
                            if (member.isOwner)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x33281508),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(0xFF8E6222),
                                  ),
                                ),
                                child: const Text(
                                  'OWNER',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.6,
                                    color: Color(0xFFFFD28A),
                                  ),
                                ),
                              ),
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