import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../models/server_model.dart';
import '../settings/yappa_settings_dialog.dart';

class ConnectScreen extends StatefulWidget {
  final AppState appState;

  const ConnectScreen({super.key, required this.appState});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  String? _selectedServerId;
  bool _useDifferentIdentity = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _selectedServerId = widget.appState.selectedServerId.isEmpty
        ? null
        : widget.appState.selectedServerId;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? get _rememberedUsername {
    final serverId = _selectedServerId;
    if (serverId == null) return null;
    if (_useDifferentIdentity) return null;
    return widget.appState.rememberedUsernameForServer(serverId);
  }

  bool get _selectedServerIsOwner {
    final serverId = _selectedServerId;
    if (serverId == null || serverId.isEmpty) {
      return false;
    }
    return widget.appState.permissionsForServer(serverId).isOwner;
  }

  Future<void> _submit() async {
    final serverId = _selectedServerId;
    if (serverId == null || serverId.isEmpty) {
      setState(() {
        _errorText = 'Pick or add a server node first.';
      });
      return;
    }

    if (_rememberedUsername != null) {
      await widget.appState.resumeSavedSession(serverId);
      if (!mounted) return;
      setState(() {
        _errorText = widget.appState.lastError;
      });
      return;
    }

    final error = await widget.appState.authenticate(
      serverId: serverId,
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;

    setState(() {
      _errorText = error;
    });
  }

  Future<void> _showJoinServerDialog() async {
    final addressController = TextEditingController();
    String? dialogError;

    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            return AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: const Text('Join a new server node'),
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
                    if (dialogError != null)
                      Text(
                        dialogError!,
                        style: const TextStyle(color: Color(0xFFFFB4BF)),
                      )
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Yappa will connect to the node and use the real server name from the backend.',
                          style: TextStyle(
                            color: NewChatColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
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

    if (!mounted || result == null) {
      return;
    }

    try {
      await widget.appState.addServerNode(address: result);

      if (!mounted) return;

      setState(() {
        _selectedServerId = widget.appState.selectedServerId.isEmpty
            ? null
            : widget.appState.selectedServerId;
        _errorText = null;
        _useDifferentIdentity = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorText = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _showSettingsDialog() async {
    await showYappaSettingsDialog(
      context: context,
      appState: widget.appState,
      onThemeChanged: () {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  Future<void> _confirmRemoveServer(String serverId) async {
    final matches =
        widget.appState.servers.where((server) => server.id == serverId).toList();
    if (matches.isEmpty) return;
    final server = matches.first;

    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: NewChatColors.panel,
          title: const Text('Remove node'),
          content: Text(
            'Remove "${server.name}" from this client?\n\nThis only removes the saved node and local session from this machine. It does not delete the actual server.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Remove'),
            ),
          ],
        );
      },
    );

    if (shouldRemove != true) return;

    await widget.appState.removeServerNode(serverId);

    if (!mounted) return;

    setState(() {
      _selectedServerId = widget.appState.servers.isNotEmpty
          ? (widget.appState.selectedServerId.isEmpty
              ? widget.appState.servers.first.id
              : widget.appState.selectedServerId)
          : null;
      _errorText = null;
      _useDifferentIdentity = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Row(
          children: [
            Expanded(
              flex: 6,
              child: _IntroPanel(
                rememberedUsername: _rememberedUsername,
                useDifferentIdentity: _useDifferentIdentity,
                selectedServerIsOwner: _selectedServerIsOwner,
                usernameController: _usernameController,
                passwordController: _passwordController,
                onUseDifferentIdentity: () {
                  setState(() {
                    _useDifferentIdentity = true;
                    _errorText = null;
                  });
                },
                onOpenSettings: _showSettingsDialog,
                errorText: _errorText,
              ),
            ),
            const SizedBox(width: 90),
            Expanded(
              flex: 5,
              child: _ServerPickerCard(
                appState: widget.appState,
                servers: widget.appState.servers,
                selectedServerId: _selectedServerId,
                rememberedUsername: _rememberedUsername,
                onJoinServer: _showJoinServerDialog,
                onRemoveServer: (serverId) {
                  _confirmRemoveServer(serverId);
                },
                onServerSelected: (serverId) {
                  setState(() {
                    _selectedServerId = serverId;
                    _errorText = null;
                    _useDifferentIdentity = false;
                  });
                },
                onConnect: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PortalSettingsButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PortalSettingsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: NewChatColors.panel,
          side: BorderSide(color: NewChatColors.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        child: Icon(
          Icons.settings_rounded,
          color: NewChatColors.textMuted,
        ),
      ),
    );
  }
}

class _IntroPanel extends StatelessWidget {
  final String? rememberedUsername;
  final bool useDifferentIdentity;
  final bool selectedServerIsOwner;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final VoidCallback onUseDifferentIdentity;
  final VoidCallback onOpenSettings;
  final String? errorText;

  const _IntroPanel({
    required this.rememberedUsername,
    required this.useDifferentIdentity,
    required this.selectedServerIsOwner,
    required this.usernameController,
    required this.passwordController,
    required this.onUseDifferentIdentity,
    required this.onOpenSettings,
    required this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final hasSavedSession = rememberedUsername != null && !useDifferentIdentity;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          right: -38,
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF130E12), Color(0xFF0D1014)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: NewChatColors.outline),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 38),
          child: Container(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: LinearGradient(
                      colors: [NewChatColors.accent, NewChatColors.accentGlow],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x553E070F),
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.verified_user_rounded, size: 30),
                ),
                const SizedBox(height: 24),
                Text(
                  hasSavedSession
                      ? 'Saved session ready'
                      : 'Enter your local identity',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  hasSavedSession
                      ? 'This server already has a remembered local session. Jump straight in, or switch identities if you want a different account.'
                      : 'Type a username and password. If that username already exists on the selected server, Yappa signs you in. If it does not, Yappa creates the local account there.',
                  style: TextStyle(
                    color: NewChatColors.textMuted,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (hasSavedSession)
                      _SignalChip(
                        icon: selectedServerIsOwner
                            ? Icons.admin_panel_settings_rounded
                            : Icons.key_rounded,
                        label: selectedServerIsOwner
                            ? 'Owner session ready as $rememberedUsername'
                            : 'Remembered as $rememberedUsername',
                      )
                    else
                      const _SignalChip(
                        icon: Icons.shield_outlined,
                        label: 'Auto-create or sign in',
                      ),
                    const _SignalChip(
                      icon: Icons.storage_rounded,
                      label: 'Node-local account model',
                    ),
                    if (selectedServerIsOwner)
                      const _SignalChip(
                        icon: Icons.tune_rounded,
                        label: 'Admin controls available',
                      ),
                  ],
                ),
                const Spacer(),
                if (hasSavedSession)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: NewChatColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedServerIsOwner
                              ? 'You already have a remembered owner session for this node.'
                              : 'You already have a remembered session for this node.',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          rememberedUsername!,
                          style: TextStyle(
                            color: NewChatColors.accentGlow,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: onUseDifferentIdentity,
                          icon: const Icon(Icons.switch_account_rounded),
                          label: const Text('Use a different identity'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  TextField(
                    controller: usernameController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'Choose or enter your name for this server',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      hintText: 'Local password for this server only',
                      prefixIcon: Icon(Icons.password_rounded),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (errorText != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF241217),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF6B2833)),
                    ),
                    child: Text(
                      errorText!,
                      style: const TextStyle(color: Color(0xFFFFB4BF)),
                    ),
                  )
                else
                  Text(
                    selectedServerIsOwner
                        ? 'Owner sessions can jump straight into channel management, server branding, and media rules.'
                        : 'This build is now using real node auth, saved session tokens, SQLite-backed messages, and live server presence.',
                    style: TextStyle(color: NewChatColors.textMuted),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 26,
          right: 6,
          child: _PortalSettingsButton(
            onPressed: onOpenSettings,
          ),
        ),
      ],
    );
  }
}

class _SignalChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SignalChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: NewChatColors.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: NewChatColors.accentGlow),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _ServerPickerCard extends StatelessWidget {
  final AppState appState;
  final List<ChatServer> servers;
  final String? selectedServerId;
  final String? rememberedUsername;
  final ValueChanged<String> onServerSelected;
  final ValueChanged<String> onRemoveServer;
  final VoidCallback onJoinServer;
  final VoidCallback onConnect;

  const _ServerPickerCard({
    required this.appState,
    required this.servers,
    required this.selectedServerId,
    required this.rememberedUsername,
    required this.onServerSelected,
    required this.onRemoveServer,
    required this.onJoinServer,
    required this.onConnect,
  });

  String? _resolvedAssetUrl(ChatServer server, String? rawUrl) {
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
    final hasSelection =
        selectedServerId != null && selectedServerId!.isNotEmpty;
    final selectedIsOwner =
        hasSelection && appState.permissionsForServer(selectedServerId!).isOwner;

    return Container(
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: NewChatColors.outline),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SELECT A SERVER NODE',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      rememberedUsername != null
                          ? selectedIsOwner
                              ? 'A saved owner session is ready on the selected node.'
                              : 'A saved local session is ready on the selected node.'
                          : 'Pick the node you want to enter, or add a new one by IP or host.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: onJoinServer,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Join Node'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: servers.isEmpty
                ? Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: NewChatColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.hub_outlined,
                          size: 40,
                          color: NewChatColors.textMuted,
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'No nodes saved yet',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Click Join Node and enter something like 127.0.0.1.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: NewChatColors.textMuted),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: servers.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      final selected = server.id == selectedServerId;
                      final isOwner =
                          appState.permissionsForServer(server.id).isOwner;
                      return _ServerPickerTile(
                        server: server,
                        selected: selected,
                        isOwner: isOwner,
                        rememberedUsername: selected ? rememberedUsername : null,
                        iconUrl: _resolvedAssetUrl(server, server.iconUrl),
                        bannerUrl: _resolvedAssetUrl(server, server.bannerUrl),
                        onTap: () => onServerSelected(server.id),
                        onRemove: () => onRemoveServer(server.id),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: hasSelection ? onConnect : null,
              icon: Icon(
                rememberedUsername != null
                    ? Icons.login_rounded
                    : Icons.arrow_forward_rounded,
              ),
              label: Text(
                rememberedUsername != null
                    ? selectedIsOwner
                        ? 'Continue as owner'
                        : 'Continue as $rememberedUsername'
                    : 'Start Chatting',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerPickerTile extends StatelessWidget {
  final ChatServer server;
  final bool selected;
  final bool isOwner;
  final String? rememberedUsername;
  final String? iconUrl;
  final String? bannerUrl;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ServerPickerTile({
    required this.server,
    required this.selected,
    required this.isOwner,
    required this.rememberedUsername,
    required this.iconUrl,
    required this.bannerUrl,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasSavedSession = rememberedUsername != null;
    final hasBanner = bannerUrl != null && bannerUrl!.isNotEmpty;
    final hasIcon = iconUrl != null && iconUrl!.isNotEmpty;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.zero,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF21141A) : NewChatColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected ? NewChatColors.accentGlow : NewChatColors.outline,
          ),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x442B050B),
                    blurRadius: 22,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23),
          child: Stack(
            children: [
              if (hasBanner)
                Positioned.fill(
                  child: Image.network(
                    bannerUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: hasBanner
                          ? const [
                              Color(0x10000000),
                              Color(0xA814171D),
                              Color(0xEE161A20),
                            ]
                          : [
                              selected
                                  ? const Color(0xFF21141A)
                                  : NewChatColors.surface,
                              selected
                                  ? const Color(0xFF1A1015)
                                  : NewChatColors.surface,
                            ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFF202530),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: NewChatColors.outline),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: hasIcon
                          ? Image.network(
                              iconUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Center(
                                  child: Text(
                                    server.shortName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 20,
                                    ),
                                  ),
                                );
                              },
                            )
                          : Center(
                              child: Text(
                                server.shortName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  server.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              if (isOwner)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
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
                                      letterSpacing: 0.7,
                                      color: Color(0xFFFFD28A),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            server.tagline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.78),
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _NodeMetaChip(
                                icon: Icons.dns_rounded,
                                label: server.address,
                              ),
                              if (hasSavedSession)
                                _NodeMetaChip(
                                  icon: Icons.login_rounded,
                                  label: 'Saved as $rememberedUsername',
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: onRemove,
                      tooltip: 'Remove node',
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: NewChatColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeMetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _NodeMetaChip({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x3A11151B),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: NewChatColors.textMuted),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}