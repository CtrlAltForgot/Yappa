import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../shared/pick_and_adjust_image.dart';

Future<void> showServerAdminDialog(
  BuildContext context, {
  required AppState appState,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _ServerAdminDialog(appState: appState),
  );
}

enum _AdminSection {
  branding,
  emojis,
  stickers,
  soundboard,
  members,
  roles,
  invites,
  access,
  bans,
}

class _ServerAdminDialog extends StatefulWidget {
  final AppState appState;

  const _ServerAdminDialog({required this.appState});

  @override
  State<_ServerAdminDialog> createState() => _ServerAdminDialogState();
}

class _ServerAdminDialogState extends State<_ServerAdminDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _accentController;
  late final TextEditingController _iconUrlController;
  late final TextEditingController _bannerUrlController;

  _AdminSection _selectedSection = _AdminSection.branding;

  bool _savingBranding = false;
  bool _uploadingIcon = false;
  bool _uploadingBanner = false;

  String? _brandingMessage;

  @override
  void initState() {
    super.initState();
    final server = widget.appState.selectedServer;
    _nameController = TextEditingController(text: server.name);
    _descriptionController = TextEditingController(text: server.description);
    _accentController = TextEditingController(text: server.accentColor);
    _iconUrlController = TextEditingController(text: server.iconUrl ?? '');
    _bannerUrlController = TextEditingController(text: server.bannerUrl ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _accentController.dispose();
    _iconUrlController.dispose();
    _bannerUrlController.dispose();
    super.dispose();
  }

  String? _resolvedAssetUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }

    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }

    final server = widget.appState.selectedServer;
    if (server.address.isEmpty) {
      return trimmed;
    }

    if (trimmed.startsWith('/')) {
      return '${server.address}$trimmed';
    }

    return '${server.address}/$trimmed';
  }

  Future<void> _saveBranding() async {
    setState(() {
      _savingBranding = true;
      _brandingMessage = null;
    });

    try {
      await widget.appState.updateSelectedServerProfile(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        accentColor: _accentController.text.trim(),
        iconUrl: _iconUrlController.text.trim().isEmpty
            ? null
            : _iconUrlController.text.trim(),
        bannerUrl: _bannerUrlController.text.trim().isEmpty
            ? null
            : _bannerUrlController.text.trim(),
      );

      if (!mounted) return;
      setState(() {
        _brandingMessage = 'Server branding saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _brandingMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingBranding = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadBrandingAsset(String slot) async {
    setState(() {
      if (slot == 'icon') {
        _uploadingIcon = true;
      } else {
        _uploadingBanner = true;
      }
      _brandingMessage = null;
    });

    Directory? tempDir;
    try {
      final picked = await pickAndAdjustImage(
        context: context,
        aspectRatio: slot == 'icon' ? 1 : 16 / 5,
        title: slot == 'icon' ? 'Crop server icon' : 'Crop server banner',
        maxOutputDimension: slot == 'icon' ? 512 : 1600,
      );

      if (!mounted) return;

      if (picked == null) {
        setState(() {
          _brandingMessage = 'No image selected.';
        });
        return;
      }

      tempDir = await Directory.systemTemp.createTemp('yappa_branding_');
      final uploadFile = File('${tempDir.path}/$slot.${picked.extension}');
      await uploadFile.writeAsBytes(picked.bytes, flush: true);

      final updatedServer =
          await widget.appState.uploadSelectedServerBrandingAsset(
        slot: slot,
        file: uploadFile,
      );

      if (!mounted) return;

      _iconUrlController.text = updatedServer.iconUrl ?? '';
      _bannerUrlController.text = updatedServer.bannerUrl ?? '';
      _nameController.text = updatedServer.name;
      _descriptionController.text = updatedServer.description;
      _accentController.text = updatedServer.accentColor;

      setState(() {
        _brandingMessage =
            slot == 'icon' ? 'Server icon uploaded.' : 'Server banner uploaded.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _brandingMessage = error.toString();
      });
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          if (slot == 'icon') {
            _uploadingIcon = false;
          } else {
            _uploadingBanner = false;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.appState.selectedServer;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: NewChatColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 1180,
          maxHeight: 820,
        ),
        child: Row(
          children: [
            _AdminSidebar(
              serverName: server.name,
              selectedSection: _selectedSection,
              onSectionSelected: (section) {
                setState(() {
                  _selectedSection = section;
                });
              },
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: NewChatColors.outline),
                  ),
                ),
                child: Column(
                  children: [
                    _AdminContentHeader(section: _selectedSection),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        child: KeyedSubtree(
                          key: ValueKey(_selectedSection),
                          child: _buildSectionContent(),
                        ),
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

  Widget _buildSectionContent() {
    switch (_selectedSection) {
      case _AdminSection.branding:
        return _buildBrandingSection();
      case _AdminSection.emojis:
        return _buildPlaceholderSection(
          icon: Icons.emoji_emotions_outlined,
          title: 'Emojis',
          subtitle: 'Custom emoji support menu scaffold.',
          description:
              'This page is ready for server emoji management later. We can wire up upload slots, emoji limits, and permissions next.',
          bullets: const [
            'Upload and preview custom server emojis',
            'Show emoji slots used and remaining',
            'Control who can manage emoji assets',
          ],
        );
      case _AdminSection.stickers:
        return _buildPlaceholderSection(
          icon: Icons.sticky_note_2_outlined,
          title: 'Stickers',
          subtitle: 'Custom sticker support menu scaffold.',
          description:
              'This section is laid out and ready for sticker uploads, preview cards, and sticker limits once you want to build the feature itself.',
          bullets: const [
            'Add sticker packs to the server',
            'Preview sticker art and metadata',
            'Set future sticker permissions and limits',
          ],
        );
      case _AdminSection.soundboard:
        return _buildPlaceholderSection(
          icon: Icons.graphic_eq_rounded,
          title: 'Soundboard',
          subtitle: 'Custom soundboard support menu scaffold.',
          description:
              'This page can later hold sound uploads, playback previews, categories, and moderator controls for voice decks.',
          bullets: const [
            'Upload short sound clips',
            'Preview and organize soundboard slots',
            'Choose who can trigger soundboard sounds',
          ],
        );
      case _AdminSection.members:
        return _buildPlaceholderSection(
          icon: Icons.groups_2_outlined,
          title: 'Members',
          subtitle: 'Server member management menu scaffold.',
          description:
              'The list and layout are reserved for a proper member manager with search, profiles, role assignment, and moderation shortcuts.',
          bullets: const [
            'Browse every member in the server',
            'Inspect profile and activity details',
            'Jump to roles, access, or moderation actions',
          ],
        );
      case _AdminSection.roles:
        return _buildPlaceholderSection(
          icon: Icons.security_rounded,
          title: 'Roles',
          subtitle: 'Roles and permissions menu scaffold.',
          description:
              'This section is ready for custom role stacks, permission toggles, colors, icons, and future hierarchy tools.',
          bullets: const [
            'Create and reorder server roles',
            'Define permissions for text, voice, and admin',
            'Control role colors, icons, and visibility',
          ],
        );
      case _AdminSection.invites:
        return _buildPlaceholderSection(
          icon: Icons.mail_outline_rounded,
          title: 'Invites',
          subtitle: 'Custom invite management menu scaffold.',
          description:
              'This area is reserved for invite links, expiry rules, one-time use settings, and invite analytics later on.',
          bullets: const [
            'Create reusable or expiring invites',
            'Track who created and used each invite',
            'Manage invite restrictions and cleanup',
          ],
        );
      case _AdminSection.access:
        return _buildPlaceholderSection(
          icon: Icons.vpn_key_outlined,
          title: 'Access',
          subtitle: 'Whitelist and entry rule menu scaffold.',
          description:
              'This page is where password protection, invite-only mode, whitelists, and other entry gates can live when you are ready.',
          bullets: const [
            'Require a password before joining',
            'Switch the server to invite-only mode',
            'Set whitelist or approval-based access rules',
          ],
        );
      case _AdminSection.bans:
        return _buildPlaceholderSection(
          icon: Icons.block_outlined,
          title: 'Bans',
          subtitle: 'Ban manager menu scaffold.',
          description:
              'This section can later show banned users, ban reasons, timestamps, and one-click unban tools.',
          bullets: const [
            'Review every banned user',
            'Inspect reasons and moderation history',
            'Unban users from one central screen',
          ],
        );
    }
  }

  Widget _buildBrandingSection() {
    final server = widget.appState.selectedServer;
    final currentIconUrl = server.iconUrl ?? _iconUrlController.text;
    final currentBannerUrl = server.bannerUrl ?? _bannerUrlController.text;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;

          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionCard(
                title: 'Server branding',
                subtitle:
                    'Change the server name, description, accent color, icon, and banner.',
                child: Column(
                  children: [
                    TextField(
                      controller: _nameController,
                      decoration: _decoration(
                        'Server name',
                        hint: 'Night Wire',
                        icon: Icons.hub_rounded,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _descriptionController,
                      minLines: 4,
                      maxLines: 6,
                      decoration: _decoration(
                        'Description',
                        hint: 'quiet grid for testing strange ideas',
                        icon: Icons.notes_rounded,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _accentController,
                      decoration: _decoration(
                        'Accent color',
                        hint: '#7B1424',
                        icon: Icons.palette_outlined,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _buildSectionCard(
                title: 'Branding assets',
                subtitle:
                    'Paste image URLs or upload cropped assets directly to your server node.',
                child: Column(
                  children: [
                    TextField(
                      controller: _iconUrlController,
                      decoration: _decoration(
                        'Icon URL',
                        hint: 'https://example.com/icon.png',
                        icon: Icons.image_outlined,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _uploadingIcon
                              ? null
                              : () => _pickAndUploadBrandingAsset('icon'),
                          icon: _uploadingIcon
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_rounded),
                          label: const Text('Choose Icon'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Uploads the cropped icon asset to this server.',
                            style: TextStyle(
                              color: NewChatColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _bannerUrlController,
                      decoration: _decoration(
                        'Banner URL',
                        hint: 'https://example.com/banner.png',
                        icon: Icons.photo_rounded,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _uploadingBanner
                              ? null
                              : () => _pickAndUploadBrandingAsset('banner'),
                          icon: _uploadingBanner
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_file_rounded),
                          label: const Text('Choose Banner'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Best for self-hosted banner art and server identity images.',
                            style: TextStyle(
                              color: NewChatColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_brandingMessage != null) ...[
                const SizedBox(height: 18),
                _buildMessage(_brandingMessage),
              ],
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _savingBranding ? null : _saveBranding,
                  icon: _savingBranding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_rounded),
                  label: const Text('Save server branding'),
                ),
              ),
            ],
          );

          final right = Column(
            children: [
              _buildAssetPreviewCard(
                title: 'Current icon preview',
                rawUrl: currentIconUrl,
                height: 180,
                fallbackIcon: Icons.image_rounded,
              ),
              const SizedBox(height: 18),
              _buildAssetPreviewCard(
                title: 'Current banner preview',
                rawUrl: currentBannerUrl,
                height: 180,
                fallbackIcon: Icons.photo_rounded,
              ),
              const SizedBox(height: 18),
              _buildMockServerCardPreview(
                serverName: _nameController.text.trim().isEmpty
                    ? server.name
                    : _nameController.text.trim(),
                description: _descriptionController.text.trim().isEmpty
                    ? 'No description yet.'
                    : _descriptionController.text.trim(),
                iconUrl: currentIconUrl,
                bannerUrl: currentBannerUrl,
              ),
            ],
          );

          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 7, child: left),
                const SizedBox(width: 18),
                Expanded(flex: 5, child: right),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              left,
              const SizedBox(height: 18),
              right,
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlaceholderSection({
    required IconData icon,
    required String title,
    required String subtitle,
    required String description,
    required List<String> bullets,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: _buildSectionCard(
        title: title,
        subtitle: subtitle,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: NewChatColors.panelAlt,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: NewChatColors.outline),
              ),
              child: Icon(icon, color: NewChatColors.accentGlow),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description,
                    style: TextStyle(
                      color: NewChatColors.textMuted,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.construction_rounded,
                              size: 16,
                              color: NewChatColors.warning,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Menu scaffold only for now',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ...bullets.map(
                          (bullet) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 7),
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: NewChatColors.accentGlow,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    bullet,
                                    style: TextStyle(
                                      color: NewChatColors.textMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
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
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _buildMessage(String? message) {
    if (message == null || message.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: NewChatColors.textMuted,
          fontSize: 12,
        ),
      ),
    );
  }

  InputDecoration _decoration(
    String label, {
    String? hint,
    IconData? icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon),
    );
  }

  Widget _buildAssetPreviewCard({
    required String title,
    required String? rawUrl,
    required double height,
    required IconData fallbackIcon,
  }) {
    final resolvedUrl = _resolvedAssetUrl(rawUrl);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: height,
              width: double.infinity,
              color: NewChatColors.panelAlt,
              child: resolvedUrl == null
                  ? Center(
                      child: Icon(
                        fallbackIcon,
                        size: 34,
                        color: NewChatColors.textMuted,
                      ),
                    )
                  : Image.network(
                      resolvedUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Center(
                          child: Icon(
                            fallbackIcon,
                            size: 34,
                            color: NewChatColors.textMuted,
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            resolvedUrl ?? 'No image set yet.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMockServerCardPreview({
    required String serverName,
    required String description,
    required String? iconUrl,
    required String? bannerUrl,
  }) {
    final resolvedBannerUrl = _resolvedAssetUrl(bannerUrl);
    final resolvedIconUrl = _resolvedAssetUrl(iconUrl);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick preview',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: NewChatColors.panelAlt,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: NewChatColors.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 110,
                  width: double.infinity,
                  child: resolvedBannerUrl == null
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                NewChatColors.accentGlow.withValues(alpha: 0.92),
                                NewChatColors.accent.withValues(alpha: 0.74),
                              ],
                            ),
                          ),
                        )
                      : Image.network(
                          resolvedBannerUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    NewChatColors.accentGlow.withValues(alpha: 0.92),
                                    NewChatColors.accent.withValues(alpha: 0.74),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Transform.translate(
                    offset: const Offset(0, -28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: NewChatColors.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: NewChatColors.panel,
                              width: 4,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: resolvedIconUrl == null
                              ? Icon(
                                  Icons.image_rounded,
                                  color: NewChatColors.textMuted,
                                  size: 28,
                                )
                              : Image.network(
                                  resolvedIconUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Icon(
                                      Icons.image_rounded,
                                      color: NewChatColors.textMuted,
                                      size: 28,
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          serverName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: NewChatColors.textMuted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
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

class _AdminContentHeader extends StatelessWidget {
  final _AdminSection section;

  const _AdminContentHeader({required this.section});

  @override
  Widget build(BuildContext context) {
    final meta = _sectionMeta(section);

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: NewChatColors.outline),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: NewChatColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: NewChatColors.outline),
            ),
            child: Icon(meta.icon, color: NewChatColors.accentGlow),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.label, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  meta.description,
                  style: TextStyle(
                    color: NewChatColors.textMuted,
                    fontSize: 13,
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

class _AdminSidebar extends StatelessWidget {
  final String serverName;
  final _AdminSection selectedSection;
  final ValueChanged<_AdminSection> onSectionSelected;
  final VoidCallback onClose;

  const _AdminSidebar({
    required this.serverName,
    required this.selectedSection,
    required this.onSectionSelected,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: NewChatColors.panel,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          bottomLeft: Radius.circular(28),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Server Admin',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        serverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: NewChatColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: NewChatColors.outline),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
              children: [
                _AdminCategorySection(
                  title: 'SERVER',
                  items: const [_AdminSection.branding],
                  selectedSection: selectedSection,
                  onSectionSelected: onSectionSelected,
                ),
                const SizedBox(height: 16),
                _AdminCategorySection(
                  title: 'EXPRESSION',
                  items: const [
                    _AdminSection.emojis,
                    _AdminSection.stickers,
                    _AdminSection.soundboard,
                  ],
                  selectedSection: selectedSection,
                  onSectionSelected: onSectionSelected,
                ),
                const SizedBox(height: 16),
                _AdminCategorySection(
                  title: 'PEOPLE',
                  items: const [
                    _AdminSection.members,
                    _AdminSection.roles,
                    _AdminSection.invites,
                    _AdminSection.access,
                    _AdminSection.bans,
                  ],
                  selectedSection: selectedSection,
                  onSectionSelected: onSectionSelected,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminCategorySection extends StatelessWidget {
  final String title;
  final List<_AdminSection> items;
  final _AdminSection selectedSection;
  final ValueChanged<_AdminSection> onSectionSelected;

  const _AdminCategorySection({
    required this.title,
    required this.items,
    required this.selectedSection,
    required this.onSectionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Text(
            title,
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ...items.map(
          (section) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _AdminSidebarButton(
              meta: _sectionMeta(section),
              selected: selectedSection == section,
              onTap: () => onSectionSelected(section),
            ),
          ),
        ),
      ],
    );
  }
}

class _AdminSidebarButton extends StatelessWidget {
  final _AdminSectionMeta meta;
  final bool selected;
  final VoidCallback onTap;

  const _AdminSidebarButton({
    required this.meta,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final background = selected ? NewChatColors.surface : Colors.transparent;
    final borderColor = selected ? NewChatColors.outline : Colors.transparent;
    final textColor = selected ? Colors.white : NewChatColors.textMuted;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(meta.icon, size: 18, color: textColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  meta.label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
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

class _AdminSectionMeta {
  final String label;
  final String description;
  final IconData icon;

  const _AdminSectionMeta({
    required this.label,
    required this.description,
    required this.icon,
  });
}

_AdminSectionMeta _sectionMeta(_AdminSection section) {
  switch (section) {
    case _AdminSection.branding:
      return const _AdminSectionMeta(
        label: 'Server Branding',
        description: 'Change the server name, icon, banner, and visual identity.',
        icon: Icons.style_rounded,
      );
    case _AdminSection.emojis:
      return const _AdminSectionMeta(
        label: 'Emojis',
        description: 'Custom emoji support and management will live here.',
        icon: Icons.emoji_emotions_outlined,
      );
    case _AdminSection.stickers:
      return const _AdminSectionMeta(
        label: 'Stickers',
        description: 'Custom sticker support and sticker library controls.',
        icon: Icons.sticky_note_2_outlined,
      );
    case _AdminSection.soundboard:
      return const _AdminSectionMeta(
        label: 'Soundboard',
        description: 'Upload and manage custom soundboard clips.',
        icon: Icons.graphic_eq_rounded,
      );
    case _AdminSection.members:
      return const _AdminSectionMeta(
        label: 'Members',
        description: 'Manage all server members and their information.',
        icon: Icons.groups_2_outlined,
      );
    case _AdminSection.roles:
      return const _AdminSectionMeta(
        label: 'Roles',
        description: 'Create custom roles and assign permissions.',
        icon: Icons.security_rounded,
      );
    case _AdminSection.invites:
      return const _AdminSectionMeta(
        label: 'Invites',
        description: 'Create and manage invite links and join flows.',
        icon: Icons.mail_outline_rounded,
      );
    case _AdminSection.access:
      return const _AdminSectionMeta(
        label: 'Access',
        description: 'Password, invite-only, and whitelist-style access rules.',
        icon: Icons.vpn_key_outlined,
      );
    case _AdminSection.bans:
      return const _AdminSectionMeta(
        label: 'Bans',
        description: 'Review and manage the server ban list.',
        icon: Icons.block_outlined,
      );
  }
}
