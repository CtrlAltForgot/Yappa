import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/server_model.dart';

class ServerSidebar extends StatelessWidget {
  final List<ChatServer> servers;
  final String selectedServerId;
  final ValueChanged<String> onServerSelected;
  final VoidCallback onAddServer;

  const ServerSidebar({
    super.key,
    required this.servers,
    required this.selectedServerId,
    required this.onServerSelected,
    required this.onAddServer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      color: NewChatColors.panel,
      child: Column(
        children: [
          const SizedBox(height: 16),
          const _RailGlyph(),
          const SizedBox(height: 18),
          for (final server in servers)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ServerButton(
                server: server,
                selected: server.id == selectedServerId,
                onTap: () => onServerSelected(server.id),
              ),
            ),
          const Spacer(),
          GestureDetector(
            onTap: onAddServer,
            child: Container(
              width: 56,
              height: 56,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: NewChatColors.surface,
                border: Border.all(color: NewChatColors.outline),
              ),
              child: Icon(Icons.add, color: NewChatColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailGlyph extends StatelessWidget {
  const _RailGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [NewChatColors.accent, NewChatColors.accentGlow],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Center(
        child: Text(
          'N',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _ServerButton extends StatelessWidget {
  final ChatServer server;
  final bool selected;
  final VoidCallback onTap;

  const _ServerButton({
    required this.server,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(selected ? 22 : 20),
          color: selected ? NewChatColors.accent : NewChatColors.surface,
          border: Border.all(
            color: selected ? NewChatColors.accentGlow : NewChatColors.outline,
            width: 1.2,
          ),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x552A0006),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            server.shortName,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}