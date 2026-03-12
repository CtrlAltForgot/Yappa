import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/api_client.dart';
import '../../models/channel_model.dart';

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

class _ServerAdminDialog extends StatefulWidget {
  final AppState appState;

  const _ServerAdminDialog({required this.appState});

  @override
  State<_ServerAdminDialog> createState() => _ServerAdminDialogState();
}

class _ServerAdminDialogState extends State<_ServerAdminDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _accentController;
  late final TextEditingController _iconUrlController;
  late final TextEditingController _bannerUrlController;

  late final TextEditingController _newChannelNameController;
  ChannelType _newChannelType = ChannelType.text;

  late final TextEditingController _attachmentRetentionController;
  late final TextEditingController _attachmentMaxMbController;
  late final TextEditingController _storageTotalMbController;
  late final TextEditingController _storagePerFileMbController;
  late final TextEditingController _attachmentTypesController;
  late final TextEditingController _storageTypesController;

  bool _fileStorageEnabled = true;
  bool _inlineMediaPreviewsEnabled = true;

  bool _loadingSettings = true;
  bool _savingOverview = false;
  bool _savingSettings = false;
  bool _creatingChannel = false;
  bool _uploadingIcon = false;
  bool _uploadingBanner = false;

  String? _overviewMessage;
  String? _channelMessage;
  String? _settingsMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    final server = widget.appState.selectedServer;

    _nameController = TextEditingController(text: server.name);
    _descriptionController = TextEditingController(text: server.description);
    _accentController = TextEditingController(text: server.accentColor);
    _iconUrlController = TextEditingController(text: server.iconUrl ?? '');
    _bannerUrlController = TextEditingController(text: server.bannerUrl ?? '');

    _newChannelNameController = TextEditingController();

    _attachmentRetentionController = TextEditingController();
    _attachmentMaxMbController = TextEditingController();
    _storageTotalMbController = TextEditingController();
    _storagePerFileMbController = TextEditingController();
    _attachmentTypesController = TextEditingController();
    _storageTypesController = TextEditingController();

    _primeSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();

    _nameController.dispose();
    _descriptionController.dispose();
    _accentController.dispose();
    _iconUrlController.dispose();
    _bannerUrlController.dispose();

    _newChannelNameController.dispose();

    _attachmentRetentionController.dispose();
    _attachmentMaxMbController.dispose();
    _storageTotalMbController.dispose();
    _storagePerFileMbController.dispose();
    _attachmentTypesController.dispose();
    _storageTypesController.dispose();

    super.dispose();
  }

  Future<void> _primeSettings() async {
    try {
      final settings = await widget.appState.ensureSelectedServerSettingsLoaded();
      if (!mounted) return;

      if (settings != null) {
        _applySettings(settings);
      }

      setState(() {
        _loadingSettings = false;
        _settingsMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingSettings = false;
        _settingsMessage = error.toString();
      });
    }
  }

  void _applySettings(ServerSettings settings) {
    _attachmentRetentionController.text =
        settings.attachmentRetentionDays.toString();
    _attachmentMaxMbController.text =
        _bytesToWholeMb(settings.attachmentMaxBytes).toString();
    _storageTotalMbController.text =
        _bytesToWholeMb(settings.fileStorageMaxTotalBytes).toString();
    _storagePerFileMbController.text =
        _bytesToWholeMb(settings.fileStorageMaxFileBytes).toString();
    _attachmentTypesController.text = settings.attachmentAllowedTypes.join(', ');
    _storageTypesController.text = settings.fileStorageAllowedTypes.join(', ');
    _fileStorageEnabled = settings.fileStorageEnabled;
    _inlineMediaPreviewsEnabled = settings.inlineMediaPreviewsEnabled;
  }

  int _bytesToWholeMb(int bytes) {
    final mb = (bytes / (1024 * 1024)).round();
    return mb <= 0 ? 1 : mb;
  }

  int _mbToBytes(String value, int fallbackMb) {
    final parsed = int.tryParse(value.trim());
    final safeMb = parsed == null || parsed <= 0 ? fallbackMb : parsed;
    return safeMb * 1024 * 1024;
  }

  List<String> _splitCsv(String text, {List<String> fallback = const []}) {
    final parts = text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();

    return parts.isEmpty ? fallback : parts;
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

  Future<void> _saveOverview() async {
    setState(() {
      _savingOverview = true;
      _overviewMessage = null;
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
        _overviewMessage = 'Server details saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _overviewMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingOverview = false;
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
      _overviewMessage = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );

      if (!mounted) return;

      if (result == null || result.files.isEmpty) {
        setState(() {
          _overviewMessage = 'No image selected.';
        });
        return;
      }

      final pickedPath = result.files.single.path;
      if (pickedPath == null || pickedPath.trim().isEmpty) {
        setState(() {
          _overviewMessage = 'That file could not be read from disk.';
        });
        return;
      }

      final updatedServer = await widget.appState.uploadSelectedServerBrandingAsset(
        slot: slot,
        file: File(pickedPath),
      );

      if (!mounted) return;

      _iconUrlController.text = updatedServer.iconUrl ?? '';
      _bannerUrlController.text = updatedServer.bannerUrl ?? '';
      _nameController.text = updatedServer.name;
      _descriptionController.text = updatedServer.description;
      _accentController.text = updatedServer.accentColor;

      setState(() {
        _overviewMessage =
            slot == 'icon' ? 'Server icon uploaded.' : 'Server banner uploaded.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _overviewMessage = error.toString();
      });
    } finally {
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

  Future<void> _createChannel() async {
    final name = _newChannelNameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _channelMessage = 'Enter a channel name first.';
      });
      return;
    }

    setState(() {
      _creatingChannel = true;
      _channelMessage = null;
    });

    try {
      await widget.appState.createChannelOnSelectedServer(
        name: name,
        type: _newChannelType,
      );

      if (!mounted) return;
      setState(() {
        _newChannelNameController.clear();
        _channelMessage = 'Channel created.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _channelMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _creatingChannel = false;
        });
      }
    }
  }

  Future<void> _saveSettings() async {
    final retentionDays =
        int.tryParse(_attachmentRetentionController.text.trim()) ?? 30;

    setState(() {
      _savingSettings = true;
      _settingsMessage = null;
    });

    try {
      final settings = await widget.appState.updateSelectedServerSettings(
        patch: {
          'attachmentRetentionDays': retentionDays <= 0 ? 30 : retentionDays,
          'attachmentMaxBytes': _mbToBytes(_attachmentMaxMbController.text, 25),
          'attachmentAllowedTypes': _splitCsv(
            _attachmentTypesController.text,
            fallback: const ['image/*', 'video/*', 'text/*', 'application/pdf'],
          ),
          'fileStorageEnabled': _fileStorageEnabled,
          'fileStorageMaxTotalBytes':
              _mbToBytes(_storageTotalMbController.text, 2048),
          'fileStorageMaxFileBytes':
              _mbToBytes(_storagePerFileMbController.text, 250),
          'fileStorageAllowedTypes': _splitCsv(
            _storageTypesController.text,
            fallback: const ['*'],
          ),
          'inlineMediaPreviewsEnabled': _inlineMediaPreviewsEnabled,
        },
      );

      if (!mounted) return;
      _applySettings(settings);

      setState(() {
        _settingsMessage = 'Media and file settings saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingSettings = false;
        });
      }
    }
  }

  Widget _buildMessage(String? message) {
    if (message == null || message.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(16),
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

  Widget _buildAssetPreview({
    required String title,
    required String? rawUrl,
    required double height,
    required IconData fallbackIcon,
  }) {
    final resolvedUrl = _resolvedAssetUrl(rawUrl);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
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
          const SizedBox(height: 8),
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

  @override
  Widget build(BuildContext context) {
    final server = widget.appState.selectedServer;
    final channels = widget.appState.channelsForSelectedServer;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: NewChatColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 920,
          maxHeight: 760,
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
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
                    child: const Icon(Icons.admin_panel_settings_rounded),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Owner Controls',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          server.name,
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
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Material(
              color: Colors.transparent,
              child: TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Channels'),
                  Tab(text: 'Media'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildOverviewTab(),
                  _buildChannelsTab(channels),
                  _buildMediaTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewTab() {
    final currentServer = widget.appState.selectedServer;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Server identity',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Change the node name, description, and branding that users see when they connect.',
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 18),
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
            minLines: 3,
            maxLines: 5,
            decoration: _decoration(
              'Description / tagline',
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
          const SizedBox(height: 22),
          Text(
            'Branding assets',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You can either paste URLs manually or upload raw image files directly to the server.',
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;
              final children = [
                Expanded(
                  child: _buildAssetPreview(
                    title: 'Current icon preview',
                    rawUrl: currentServer.iconUrl ?? _iconUrlController.text,
                    height: 160,
                    fallbackIcon: Icons.image_rounded,
                  ),
                ),
                const SizedBox(width: 14, height: 14),
                Expanded(
                  child: _buildAssetPreview(
                    title: 'Current banner preview',
                    rawUrl: currentServer.bannerUrl ?? _bannerUrlController.text,
                    height: 160,
                    fallbackIcon: Icons.photo_rounded,
                  ),
                ),
              ];

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                );
              }

              return Column(children: children);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _iconUrlController,
            decoration: _decoration(
              'Icon URL',
              hint: 'https://example.com/icon.png',
              icon: Icons.image_outlined,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _uploadingIcon ? null : () => _pickAndUploadBrandingAsset('icon'),
                icon: _uploadingIcon
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_rounded),
                label: const Text('Choose Icon'),
              ),
              const SizedBox(width: 10),
              Text(
                'Uploads to this server node.',
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _bannerUrlController,
            decoration: _decoration(
              'Banner URL',
              hint: 'https://example.com/banner.png',
              icon: Icons.image_rounded,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed:
                    _uploadingBanner ? null : () => _pickAndUploadBrandingAsset('banner'),
                icon: _uploadingBanner
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_rounded),
                label: const Text('Choose Banner'),
              ),
              const SizedBox(width: 10),
              Text(
                'Best for self-hosted branding assets.',
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          _buildMessage(_overviewMessage),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _savingOverview ? null : _saveOverview,
              icon: _savingOverview
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: const Text('Save overview'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelsTab(List<ChatChannel> channels) {
    final textChannels =
        channels.where((channel) => channel.type == ChannelType.text).toList();
    final voiceChannels =
        channels.where((channel) => channel.type == ChannelType.voice).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Create channels',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add new text feeds and voice decks. Reordering and deletion can come next.',
            style: TextStyle(
              color: NewChatColors.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _newChannelNameController,
            decoration: _decoration(
              'Channel name',
              hint: 'general',
              icon: Icons.alternate_email_rounded,
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<ChannelType>(
            segments: const [
              ButtonSegment<ChannelType>(
                value: ChannelType.text,
                icon: Icon(Icons.notes_rounded),
                label: Text('Text feed'),
              ),
              ButtonSegment<ChannelType>(
                value: ChannelType.voice,
                icon: Icon(Icons.graphic_eq_rounded),
                label: Text('Voice deck'),
              ),
            ],
            selected: {_newChannelType},
            onSelectionChanged: (selection) {
              setState(() {
                _newChannelType = selection.first;
              });
            },
          ),
          _buildMessage(_channelMessage),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _creatingChannel ? null : _createChannel,
              icon: _creatingChannel
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded),
              label: const Text('Create channel'),
            ),
          ),
          const SizedBox(height: 24),
          _ChannelGroupCard(
            title: 'Text feeds',
            icon: Icons.notes_rounded,
            channels: textChannels,
          ),
          const SizedBox(height: 16),
          _ChannelGroupCard(
            title: 'Voice decks',
            icon: Icons.graphic_eq_rounded,
            channels: voiceChannels,
          ),
        ],
      ),
    );
  }

  Widget _buildMediaTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _loadingSettings
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Media and file rules',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Control attachment retention, upload caps, file storage, and inline previews.',
                  style: TextStyle(
                    color: NewChatColors.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _attachmentRetentionController,
                  keyboardType: TextInputType.number,
                  decoration: _decoration(
                    'Attachment retention (days)',
                    hint: '30',
                    icon: Icons.schedule_rounded,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _attachmentMaxMbController,
                  keyboardType: TextInputType.number,
                  decoration: _decoration(
                    'Attachment max size (MB)',
                    hint: '25',
                    icon: Icons.attach_file_rounded,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _attachmentTypesController,
                  decoration: _decoration(
                    'Allowed attachment MIME types',
                    hint: 'image/*, video/*, text/*, application/pdf',
                    icon: Icons.rule_folder_outlined,
                  ),
                ),
                const SizedBox(height: 18),
                SwitchListTile(
                  value: _fileStorageEnabled,
                  onChanged: (value) {
                    setState(() {
                      _fileStorageEnabled = value;
                    });
                  },
                  title: const Text('Enable shared file storage'),
                  subtitle: Text(
                    'Allow uploads to live in the server file pool.',
                    style: TextStyle(color: NewChatColors.textMuted),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _storageTotalMbController,
                  keyboardType: TextInputType.number,
                  decoration: _decoration(
                    'Total file storage cap (MB)',
                    hint: '2048',
                    icon: Icons.storage_rounded,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _storagePerFileMbController,
                  keyboardType: TextInputType.number,
                  decoration: _decoration(
                    'Per-file cap (MB)',
                    hint: '250',
                    icon: Icons.description_outlined,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _storageTypesController,
                  decoration: _decoration(
                    'Allowed stored file MIME types',
                    hint: '*',
                    icon: Icons.folder_open_rounded,
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: _inlineMediaPreviewsEnabled,
                  onChanged: (value) {
                    setState(() {
                      _inlineMediaPreviewsEnabled = value;
                    });
                  },
                  title: const Text('Inline media previews'),
                  subtitle: Text(
                    'Show images and supported media directly inside chat.',
                    style: TextStyle(color: NewChatColors.textMuted),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                _buildMessage(_settingsMessage),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _savingSettings ? null : _saveSettings,
                    icon: _savingSettings
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_as_rounded),
                    label: const Text('Save media rules'),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChannelGroupCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<ChatChannel> channels;

  const _ChannelGroupCard({
    required this.title,
    required this.icon,
    required this.channels,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: NewChatColors.textMuted),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (channels.isEmpty)
            Text(
              'No channels yet.',
              style: TextStyle(
                color: NewChatColors.textMuted,
                fontSize: 13,
              ),
            )
          else
            ...channels.map(
              (channel) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: NewChatColors.panelAlt,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: NewChatColors.outline),
                ),
                child: Row(
                  children: [
                    Icon(
                      channel.type == ChannelType.text
                          ? Icons.notes_rounded
                          : Icons.graphic_eq_rounded,
                      size: 16,
                      color: NewChatColors.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        channel.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '#${channel.position}',
                      style: TextStyle(
                        color: NewChatColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}