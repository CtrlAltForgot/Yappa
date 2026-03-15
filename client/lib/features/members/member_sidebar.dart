import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/member_model.dart';
import '../../shared/avatar_image.dart';

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
        if (aRank != bRank) {
          return aRank.compareTo(bRank);
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final onlineMembers =
        sortedMembers.where((member) => member.isOnline).toList();
    final offlineMembers =
        sortedMembers.where((member) => !member.isOnline).toList();

    final items = <_SidebarListItem>[
      _SidebarListItem.header('ONLINE — ${onlineMembers.length}'),
      if (onlineMembers.isEmpty)
        const _SidebarListItem.empty('No one online right now.')
      else
        ...onlineMembers.map(_SidebarListItem.member),
      const _SidebarListItem.spacer(),
      _SidebarListItem.header('OFFLINE — ${offlineMembers.length}'),
      if (offlineMembers.isEmpty)
        const _SidebarListItem.empty('Everybody is online.')
      else
        ...offlineMembers.map(_SidebarListItem.member),
    ];

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
            height: 58,
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
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 14),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                switch (item.kind) {
                  case _SidebarListItemKind.header:
                    return _SectionHeader(label: item.label!);
                  case _SidebarListItemKind.empty:
                    return _EmptyHint(text: item.label!);
                  case _SidebarListItemKind.spacer:
                    return const SizedBox(height: 12);
                  case _SidebarListItemKind.member:
                    return _MemberTile(member: item.member!);
                }
              },
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

enum _SidebarListItemKind {
  header,
  empty,
  spacer,
  member,
}

class _SidebarListItem {
  final _SidebarListItemKind kind;
  final String? label;
  final Member? member;

  const _SidebarListItem._(this.kind, {this.label, this.member});

  factory _SidebarListItem.header(String label) {
    return _SidebarListItem._(_SidebarListItemKind.header, label: label);
  }

  const _SidebarListItem.empty(String label)
      : this._(_SidebarListItemKind.empty, label: label);

  const _SidebarListItem.spacer() : this._(_SidebarListItemKind.spacer);

  factory _SidebarListItem.member(Member member) {
    return _SidebarListItem._(_SidebarListItemKind.member, member: member);
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
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
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
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
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

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: member.isInVoiceDeck
            ? const Color(0xFF171C24)
            : NewChatColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: member.isInVoiceDeck
              ? const Color(0xFF324052)
              : NewChatColors.outline,
        ),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: member.isOwner
                      ? const Color(0xFF2A2113)
                      : NewChatColors.panelAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: _MemberAvatarImage(
                  source: member.avatarUrl,
                  fallbackInitial: initial,
                ),
              ),
              if (member.isOwner)
                Positioned(
                  left: -4,
                  top: -10,
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
              Positioned(
                right: -2,
                bottom: -2,
                child: _PresenceIndicator(member: member),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitleForMember(member),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: NewChatColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatarImage extends StatelessWidget {
  final String? source;
  final String fallbackInitial;

  const _MemberAvatarImage({
    required this.source,
    required this.fallbackInitial,
  });

  @override
  Widget build(BuildContext context) {
    return AvatarImage(
      source: source,
      fallbackInitial: fallbackInitial,
      size: 38,
      animate: true,
    );
  }
}

class _PresenceIndicator extends StatelessWidget {
  final Member member;

  const _PresenceIndicator({
    required this.member,
  });

  @override
  Widget build(BuildContext context) {
    if (member.isInVoiceDeck) {
      return const Icon(
        Icons.call_rounded,
        size: 15,
        color: Color(0xFF54D17A),
      );
    }

    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: member.isOnline
            ? const Color(0xFF54D17A)
            : NewChatColors.textMuted,
        shape: BoxShape.circle,
        border: Border.all(
          color: NewChatColors.panel,
          width: 2,
        ),
      ),
    );
  }
}
