import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/member_model.dart';

class MemberSidebar extends StatelessWidget {
  final List<Member> members;

  const MemberSidebar({
    super.key,
    required this.members,
  });

  @override
  Widget build(BuildContext context) {
    final sortedMembers = [...members]..sort((a, b) {
        final aRank = _sortRank(a);
        final bRank = _sortRank(b);
        if (aRank != bRank) return aRank.compareTo(bRank);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final onlineMembers =
        sortedMembers.where((member) => member.isOnline).toList();
    final offlineMembers =
        sortedMembers.where((member) => !member.isOnline).toList();

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        border: Border(
          left: BorderSide(color: NewChatColors.outline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: NewChatColors.outline),
              ),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              'Members • ${members.length}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
              children: [
                _SectionHeader(
                  label: 'ONLINE — ${onlineMembers.length}',
                ),
                if (onlineMembers.isEmpty)
                  const _EmptyHint(
                    text: 'No one online right now.',
                  )
                else
                  ...onlineMembers.map((member) => _MemberTile(member: member)),
                const SizedBox(height: 16),
                _SectionHeader(
                  label: 'OFFLINE — ${offlineMembers.length}',
                ),
                if (offlineMembers.isEmpty)
                  const _EmptyHint(
                    text: 'Everybody is online.',
                  )
                else
                  ...offlineMembers.map((member) => _MemberTile(member: member)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _sortRank(Member member) {
    if (member.isInVoiceDeck) return 0;
    if (member.isOnline) return 1;
    return 2;
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Text(
        label,
        style: TextStyle(
          color: NewChatColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
      child: Text(
        text,
        style: TextStyle(
          color: NewChatColors.textMuted,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final Member member;

  const _MemberTile({
    required this.member,
  });

  static List<Widget> _buildBadges(Member member) {
    final badges = <Widget>[];

    if (member.voiceState.micMuted) {
      badges.add(
        const _StatusBadge(
          icon: Icons.mic_off_rounded,
          label: 'Mic muted',
          color: Color(0xFFFF667E),
        ),
      );
    }
    if (member.voiceState.audioMuted) {
      badges.add(
        const _StatusBadge(
          icon: Icons.volume_off_rounded,
          label: 'Audio muted',
          color: Color(0xFFFF667E),
        ),
      );
    }
    if (member.voiceState.cameraEnabled) {
      badges.add(
        const _StatusBadge(
          icon: Icons.videocam_rounded,
          label: 'Camera on',
          color: Color(0xFF54D17A),
        ),
      );
    }
    if (member.voiceState.screenShareEnabled) {
      badges.add(
        const _StatusBadge(
          icon: Icons.screen_share_rounded,
          label: 'Sharing',
          color: Color(0xFF54D17A),
        ),
      );
    }
    if (member.voiceState.speaking) {
      badges.add(
        const _StatusBadge(
          icon: Icons.graphic_eq_rounded,
          label: 'Speaking',
          color: Color(0xFFFFD37A),
        ),
      );
    }

    return badges;
  }

  String _subtitleForMember(Member member) {
    if (member.isInVoiceDeck) {
      return 'In a voice deck';
    }
    if (member.isOnline) {
      return member.isOwner ? 'Owner' : 'Online';
    }
    return 'Offline';
  }

  @override
  Widget build(BuildContext context) {
    final initial =
        (member.name.isNotEmpty ? member.name.characters.first : '?')
            .toUpperCase();
    final badgeList = _buildBadges(member);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: member.isInVoiceDeck
            ? const Color(0xFF171C24)
            : NewChatColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: member.isInVoiceDeck
              ? const Color(0xFF324052)
              : NewChatColors.outline,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: member.isOwner
                          ? const Color(0xFF2A2113)
                          : NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      initial,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: _PresenceDot(
                      color: member.isInVoiceDeck
                          ? const Color(0xFF5F9BFF)
                          : member.isOnline
                              ? const Color(0xFF54D17A)
                              : NewChatColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitleForMember(member),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: NewChatColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (member.isOwner)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2113),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF5F4625)),
                  ),
                  child: const Text(
                    'OWNER',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFFFFD37A),
                    ),
                  ),
                ),
            ],
          ),
          if (badgeList.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: badgeList,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PresenceDot extends StatelessWidget {
  final Color color;

  const _PresenceDot({
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: NewChatColors.panel,
          width: 2,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: NewChatColors.panelAlt,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}