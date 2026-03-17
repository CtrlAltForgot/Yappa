import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/audio_preferences.dart';
import '../../data/video_preferences.dart';

Future<void> showYappaSettingsDialog({
  required BuildContext context,
  required AppState appState,
  required VoidCallback onThemeChanged,
}) async {
  int selectedTab = 0;
  await YappaAudioPreferences.load();
  await YappaVideoPreferences.load();

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void refreshAll() {
            setDialogState(() {});
            onThemeChanged();
          }

          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            backgroundColor: Colors.transparent,
            child: Container(
              width: 1100,
              height: 720,
              decoration: BoxDecoration(
                color: NewChatColors.panel,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: NewChatColors.outline),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 40,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  Container(
                    width: 248,
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      border: Border(
                        right: BorderSide(color: NewChatColors.outline),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: NewChatColors.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: NewChatColors.outline,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: NewChatColors.panelAlt,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: NewChatColors.outline,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.settings_rounded,
                                      size: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'App Settings',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Customize Yappa',
                                          style: TextStyle(
                                            color: NewChatColors.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 22),
                            Expanded(
                              child: ListView(
                                padding: EdgeInsets.zero,
                                children: [
                                  _SettingsSidebarSection(
                                    title: 'Personalization',
                                    children: [
                                      _SettingsSidebarItem(
                                        label: 'Appearance',
                                        icon: Icons.palette_outlined,
                                        selected: selectedTab == 0,
                                        onTap: () {
                                          setDialogState(() {
                                            selectedTab = 0;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  _SettingsSidebarSection(
                                    title: 'Devices',
                                    children: [
                                      _SettingsSidebarItem(
                                        label: 'Audio',
                                        icon: Icons.mic_none_rounded,
                                        selected: selectedTab == 1,
                                        onTap: () {
                                          setDialogState(() {
                                            selectedTab = 1;
                                          });
                                        },
                                      ),
                                      _SettingsSidebarItem(
                                        label: 'Video',
                                        icon: Icons.videocam_outlined,
                                        selected: selectedTab == 2,
                                        onTap: () {
                                          setDialogState(() {
                                            selectedTab = 2;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  _SettingsSidebarSection(
                                    title: 'Extensions',
                                    children: [
                                      _SettingsSidebarItem(
                                        label: 'Plugins',
                                        icon: Icons.extension_outlined,
                                        selected: selectedTab == 3,
                                        onTap: () {
                                          setDialogState(() {
                                            selectedTab = 3;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  _SettingsSidebarSection(
                                    title: 'About',
                                    children: [
                                      _SettingsSidebarItem(
                                        label: 'Info',
                                        icon: Icons.info_outline_rounded,
                                        selected: selectedTab == 4,
                                        onTap: () {
                                          setDialogState(() {
                                            selectedTab = 4;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 22, 22, 18),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _settingsTabLabel(selectedTab),
                                  style: TextStyle(
                                    color: NewChatColors.textMuted,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Close',
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: switch (selectedTab) {
                              0 => _AppearanceSettingsTab(
                                  onChanged: refreshAll,
                                ),
                              1 => _AudioSettingsTab(
                                  appState: appState,
                                  onChanged: refreshAll,
                                ),
                              2 => Platform.isLinux
                                  ? const _VideoSettingsTab()
                                  : const _SettingsPlaceholderTab(
                                      title: 'Video settings',
                                      description:
                                          'Later this is where Yappa will expose cameras, screen share quality, capture sources, and device preview controls.',
                                      icon: Icons.videocam_rounded,
                                    ),
                              3 => const _SettingsPlaceholderTab(
                                  title: 'Plugins and themes',
                                  description:
                                      'Later this is where custom plugins, theme packs, and extension management will live.',
                                  icon: Icons.extension_rounded,
                                ),
                              _ => const _InfoSettingsTab(),
                            },
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => Navigator.of(dialogContext).pop(),
                              child: const Text('Close'),
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
        },
      );
    },
  );
}

String _settingsTabLabel(int index) {
  switch (index) {
    case 0:
      return 'Appearance';
    case 1:
      return 'Audio';
    case 2:
      return 'Video';
    case 3:
      return 'Plugins';
    default:
      return 'Info';
  }
}

class _SettingsSidebarSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSidebarSection({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: NewChatColors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.7,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

class _SettingsSidebarItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsSidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final background = selected
        ? const Color(0xFF1A212D)
        : Colors.transparent;
    final borderColor = selected
        ? NewChatColors.outline
        : Colors.transparent;
    final foreground =
        selected ? Colors.white : NewChatColors.textMuted;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: const Color(0x0FFFFFFF),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _AppearanceSettingsTab extends StatefulWidget {
  final VoidCallback onChanged;

  const _AppearanceSettingsTab({required this.onChanged});

  @override
  State<_AppearanceSettingsTab> createState() => _AppearanceSettingsTabState();
}

class _AppearanceSettingsTabState extends State<_AppearanceSettingsTab> {
  late double _hue;
  late double _saturation;
  late double _lightness;

  @override
  void initState() {
    super.initState();
    _loadFromTheme();
  }

  void _loadFromTheme() {
    final sourceColor = YappaAppearance.accentPreset == YappaAccentPreset.custom
        ? YappaAppearance.customAccentGlow
        : NewChatColors.accentGlow;
    final hsl = HSLColor.fromColor(sourceColor);
    _hue = hsl.hue;
    _saturation = hsl.saturation;
    _lightness = hsl.lightness;
  }

  Future<void> _setAccent(YappaAccentPreset preset) async {
    await YappaAppearance.setAccentPreset(preset);
    if (!mounted) return;
    setState(_loadFromTheme);
    widget.onChanged();
  }

  Future<void> _updateCustomColor({
    double? hue,
    double? saturation,
    double? lightness,
  }) async {
    _hue = hue ?? _hue;
    _saturation = saturation ?? _saturation;
    _lightness = lightness ?? _lightness;

    final color = HSLColor.fromAHSL(
      1,
      _hue,
      _saturation.clamp(0.0, 1.0),
      _lightness.clamp(0.0, 1.0),
    ).toColor();

    await YappaAppearance.setCustomAccentColor(color);
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  Future<void> _setFont(YappaFontPreset preset) async {
    await YappaAppearance.setFontPreset(preset);
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = YappaAppearance.accentPreset == YappaAccentPreset.custom;
    final customColor = HSLColor.fromAHSL(
      1,
      _hue,
      _saturation.clamp(0.0, 1.0),
      _lightness.clamp(0.0, 1.0),
    ).toColor();

    return ListView(
      children: [
        Text(
          'Appearance',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Customize the core Yappa look. These settings persist on this machine.',
          style: TextStyle(
            color: NewChatColors.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Accent color',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _AccentChoiceChip(
                label: 'Crimson',
                color: const Color(0xFFDA5368),
                selected:
                    YappaAppearance.accentPreset == YappaAccentPreset.crimson,
                onTap: () => _setAccent(YappaAccentPreset.crimson),
              ),
              const SizedBox(width: 12),
              _AccentChoiceChip(
                label: 'Violet',
                color: const Color(0xFFB07DFF),
                selected:
                    YappaAppearance.accentPreset == YappaAccentPreset.violet,
                onTap: () => _setAccent(YappaAccentPreset.violet),
              ),
              const SizedBox(width: 12),
              _AccentChoiceChip(
                label: 'Ocean',
                color: const Color(0xFF54C7EC),
                selected:
                    YappaAppearance.accentPreset == YappaAccentPreset.ocean,
                onTap: () => _setAccent(YappaAccentPreset.ocean),
              ),
              const SizedBox(width: 12),
              _AccentChoiceChip(
                label: 'Emerald',
                color: const Color(0xFF55D28E),
                selected:
                    YappaAppearance.accentPreset == YappaAccentPreset.emerald,
                onTap: () => _setAccent(YappaAccentPreset.emerald),
              ),
              const SizedBox(width: 12),
              _AccentChoiceChip(
                label: 'Amber',
                color: const Color(0xFFFFB347),
                selected:
                    YappaAppearance.accentPreset == YappaAccentPreset.amber,
                onTap: () => _setAccent(YappaAccentPreset.amber),
              ),
              const SizedBox(width: 12),
              _AccentChoiceChip(
                label: 'Custom',
                color: customColor,
                selected: isCustom,
                onTap: () => _setAccent(YappaAccentPreset.custom),
              ),
            ],
          ),
        ),
        if (isCustom) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: NewChatColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: NewChatColors.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Custom accent',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: customColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: NewChatColors.outline),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Drag the sliders to make your own accent. Yappa auto-generates the darker action shades from this color.',
                        style: TextStyle(
                          color: NewChatColors.textMuted,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _LabeledSliderRow(
                  label: 'Hue',
                  value: _hue,
                  min: 0,
                  max: 360,
                  onChanged: (value) => _updateCustomColor(hue: value),
                ),
                _LabeledSliderRow(
                  label: 'Saturation',
                  value: _saturation,
                  min: 0,
                  max: 1,
                  onChanged: (value) => _updateCustomColor(saturation: value),
                ),
                _LabeledSliderRow(
                  label: 'Lightness',
                  value: _lightness,
                  min: 0,
                  max: 1,
                  onChanged: (value) => _updateCustomColor(lightness: value),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        const Text(
          'Font style',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _FontChoiceChip(
              label: 'System',
              selected: YappaAppearance.fontPreset == YappaFontPreset.system,
              onTap: () => _setFont(YappaFontPreset.system),
            ),
            _FontChoiceChip(
              label: 'Serif',
              selected: YappaAppearance.fontPreset == YappaFontPreset.serif,
              onTap: () => _setFont(YappaFontPreset.serif),
            ),
            _FontChoiceChip(
              label: 'Monospace',
              selected:
                  YappaAppearance.fontPreset == YappaFontPreset.monospace,
              onTap: () => _setFont(YappaFontPreset.monospace),
            ),
          ],
        ),
      ],
    );
  }
}

class _AudioSettingsTab extends StatefulWidget {
  final AppState appState;
  final VoidCallback onChanged;

  const _AudioSettingsTab({
    required this.appState,
    required this.onChanged,
  });

  @override
  State<_AudioSettingsTab> createState() => _AudioSettingsTabState();
}

class _AudioSettingsTabState extends State<_AudioSettingsTab> {
  bool _loadingDevices = true;
  List<MediaDeviceInfo> _inputDevices = const [];
  List<MediaDeviceInfo> _outputDevices = const [];
  bool _capturingBinding = false;

  @override
  void initState() {
    super.initState();
    _initAudioTab();
  }

  Future<void> _initAudioTab() async {
    await _loadDevices();

    try {
      await widget.appState.ensureMicInputPermission();
      await widget.appState.startMicInputCapture();
    } catch (_) {}
  }

  Future<void> _loadDevices() async {
    if (!mounted) return;
    setState(() {
      _loadingDevices = true;
    });

    try {
      await YappaAudioPreferences.load();
      final devices = await navigator.mediaDevices.enumerateDevices();
      final inputs = devices.where((d) => d.kind == 'audioinput').toList();
      final outputs = devices.where((d) => d.kind == 'audiooutput').toList();

      if (!mounted) return;
      setState(() {
        _inputDevices = inputs;
        _outputDevices = outputs;
        _loadingDevices = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _inputDevices = const [];
        _outputDevices = const [];
        _loadingDevices = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  Future<void> _restartMicMonitor() async {
    try {
      await widget.appState.stopMicInputCapture();
    } catch (_) {}
    try {
      await widget.appState.startMicInputCapture();
    } catch (_) {}
  }

  String _deviceLabel(MediaDeviceInfo device, int index, String fallback) {
    final label = device.label.trim();
    if (label.isNotEmpty) return label;
    return '$fallback ${index + 1}';
  }

  String _modeLabel(YappaVoiceInputMode mode) {
    switch (mode) {
      case YappaVoiceInputMode.pushToTalk:
        return 'Push to Talk';
      case YappaVoiceInputMode.alwaysOn:
        return 'Always On';
      case YappaVoiceInputMode.voiceActivityDetection:
        return 'Voice Activity Detection';
    }
  }

  String? _labelForPointerButtons(int buttons) {
    if ((buttons & kPrimaryMouseButton) != 0) {
      return 'Mouse 1';
    }
    if ((buttons & kSecondaryMouseButton) != 0) {
      return 'Mouse 2';
    }
    if ((buttons & kMiddleMouseButton) != 0) {
      return 'Mouse 3';
    }
    if ((buttons & kBackMouseButton) != 0) {
      return 'Mouse 4';
    }
    if ((buttons & kForwardMouseButton) != 0) {
      return 'Mouse 5';
    }
    return null;
  }

  String _labelForLogicalKey(LogicalKeyboardKey key) {
    final label = key.keyLabel.trim();
    if (label.isNotEmpty) return label;

    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return 'Enter';
    }
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.shiftLeft) return 'Left Shift';
    if (key == LogicalKeyboardKey.shiftRight) return 'Right Shift';
    if (key == LogicalKeyboardKey.controlLeft) return 'Left Ctrl';
    if (key == LogicalKeyboardKey.controlRight) return 'Right Ctrl';
    if (key == LogicalKeyboardKey.altLeft) return 'Left Alt';
    if (key == LogicalKeyboardKey.altRight) return 'Right Alt';

    final debugName = key.debugName?.trim();
    if (debugName != null && debugName.isNotEmpty) {
      return debugName;
    }

    return 'Unknown Key';
  }

  Future<void> _capturePushToTalkKey() async {
    if (!mounted) return;

    setState(() {
      _capturingBinding = true;
    });

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      useRootNavigator: false,
      builder: (keybindDialogContext) {
        final focusNode = FocusNode();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (focusNode.canRequestFocus) {
            focusNode.requestFocus();
          }
        });

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            final mouseLabel = _labelForPointerButtons(event.buttons);
            if (mouseLabel == null) return;
            Navigator.of(keybindDialogContext).pop(mouseLabel);
          },
          child: KeyboardListener(
            autofocus: true,
            focusNode: focusNode,
            onKeyEvent: (event) {
              if (event is! KeyDownEvent) return;
              final label = _labelForLogicalKey(event.logicalKey);
              Navigator.of(keybindDialogContext).pop(label);
            },
            child: AlertDialog(
              backgroundColor: NewChatColors.panel,
              title: const Text('Set Push to Talk Key'),
              content: const Text(
                'Press a keyboard key or mouse button for Push to Talk.\n\nThis stores the binding now. The actual live hotkey hook is being wired into the focused call UI.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(keybindDialogContext).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted) return;

    setState(() {
      _capturingBinding = false;
    });

    if (result == null || result.trim().isEmpty) return;

    await _run(() async {
      await YappaAudioPreferences.setPushToTalkKeyLabel(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    final level = appState.micInputLevel.clamp(0.0, 1.0);
    final peak = appState.micInputPeak.clamp(0.0, 1.0);
    final threshold = YappaAudioPreferences.manualSensitivity.clamp(0.0, 0.95);
    final isVad =
        YappaAudioPreferences.voiceInputMode ==
        YappaVoiceInputMode.voiceActivityDetection;
    final isPtt =
        YappaAudioPreferences.voiceInputMode ==
        YappaVoiceInputMode.pushToTalk;

    return ListView(
      children: [
        Text(
          'Audio',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Set your microphone up the way people expect: choose the device, watch live mic feedback at all times, and tune voice activity detection or Push to Talk.',
          style: TextStyle(
            color: NewChatColors.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        _SettingsCard(
          title: 'Devices',
          subtitle:
              'Input affects real live mic capture. Output is saved here now, but actual remote-audio sink routing still needs a later playback pass.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loadingDevices)
                const LinearProgressIndicator()
              else ...[
                DropdownButtonFormField<String?>(
                  initialValue: YappaAudioPreferences.preferredInputDeviceId,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('System default microphone'),
                    ),
                    ...List.generate(_inputDevices.length, (index) {
                      final device = _inputDevices[index];
                      return DropdownMenuItem<String?>(
                        value: device.deviceId,
                        child: Text(
                          _deviceLabel(device, index, 'Microphone'),
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) async {
                    await _run(() async {
                      await YappaAudioPreferences.setPreferredInputDeviceId(
                        value,
                      );
                      await _restartMicMonitor();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Input device',
                    prefixIcon: Icon(Icons.mic_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String?>(
                  initialValue: YappaAudioPreferences.preferredOutputDeviceId,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('System default output'),
                    ),
                    ...List.generate(_outputDevices.length, (index) {
                      final device = _outputDevices[index];
                      return DropdownMenuItem<String?>(
                        value: device.deviceId,
                        child: Text(
                          _deviceLabel(device, index, 'Output'),
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) async {
                    await _run(() async {
                      await YappaAudioPreferences.setPreferredOutputDeviceId(
                        value,
                      );
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Output device',
                    prefixIcon: Icon(Icons.volume_up_rounded),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Voice transmission',
          subtitle:
              'Choose whether your voice is sent with Push to Talk, Always On, or Voice Activity Detection.',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ChoiceChip(
                label: const Text('Push to Talk'),
                selected: isPtt,
                onSelected: (_) async {
                  await _run(() async {
                    await YappaAudioPreferences.setVoiceInputMode(
                      YappaVoiceInputMode.pushToTalk,
                    );
                  });
                },
              ),
              ChoiceChip(
                label: const Text('Always On'),
                selected:
                    YappaAudioPreferences.voiceInputMode ==
                    YappaVoiceInputMode.alwaysOn,
                onSelected: (_) async {
                  await _run(() async {
                    await YappaAudioPreferences.setVoiceInputMode(
                      YappaVoiceInputMode.alwaysOn,
                    );
                  });
                },
              ),
              ChoiceChip(
                label: const Text('Voice Activity Detection'),
                selected: isVad,
                onSelected: (_) async {
                  await _run(() async {
                    await YappaAudioPreferences.setVoiceInputMode(
                      YappaVoiceInputMode.voiceActivityDetection,
                    );
                  });
                },
              ),
            ],
          ),
        ),
        if (isPtt) ...[
          const SizedBox(height: 18),
          _SettingsCard(
            title: 'Push to Talk keybind',
            subtitle:
                'Pick the button used for Push to Talk. This stores the binding now; the actual live hotkey hook is the next pass.',
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: NewChatColors.panelAlt,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: NewChatColors.outline),
                    ),
                    child: Text(
                      YappaAudioPreferences.pushToTalkKeyLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _capturingBinding ? null : _capturePushToTalkKey,
                  icon: const Icon(Icons.keyboard_rounded, size: 18),
                  label: Text(
                    _capturingBinding ? 'Waiting…' : 'Set key',
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Input tuning',
          subtitle:
              'Your microphone stays live here so you can visually tune your settings the same way TeamSpeak users expect.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _StatusPill(
                    label: appState.micPermissionGranted
                        ? 'Mic ready'
                        : 'Waiting for OS permission',
                    active: appState.micPermissionGranted,
                  ),
                  _StatusPill(
                    label: appState.micCaptureActive
                        ? 'Live monitor running'
                        : 'Live monitor stopped',
                    active: appState.micCaptureActive,
                  ),
                  _StatusPill(
                    label: _modeLabel(YappaAudioPreferences.voiceInputMode),
                    active: true,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _LevelBar(
                value: level,
                peak: peak,
                threshold: threshold,
              ),
              const SizedBox(height: 8),
              Text(
                appState.micInputError?.trim().isNotEmpty == true
                    ? appState.micInputError!
                    : isVad
                        ? 'Input ${(level * 100).round()}% • Peak ${(peak * 100).round()}% • VAD ${(threshold * 100).round()}%'
                        : 'Input ${(level * 100).round()}% • Peak ${(peak * 100).round()}% • Threshold ${(threshold * 100).round()}%',
                style: TextStyle(
                  color: appState.micInputError?.trim().isNotEmpty == true
                      ? const Color(0xFFFFB4BF)
                      : NewChatColors.textMuted,
                ),
              ),
              const SizedBox(height: 18),
              _LabeledSliderRow(
                label: 'Gain',
                value: YappaAudioPreferences.inputGain,
                min: 0.5,
                max: 3.0,
                displayText:
                    '${YappaAudioPreferences.inputGain.toStringAsFixed(2)}x',
                onChanged: (value) async {
                  await _run(() async {
                    await YappaAudioPreferences.setInputGain(value);
                    await _restartMicMonitor();
                  });
                },
              ),
              const SizedBox(height: 8),
              _LabeledSliderRow(
                label: 'Threshold',
                value: YappaAudioPreferences.manualSensitivity,
                min: 0.0,
                max: 0.95,
                displayText:
                    '${(YappaAudioPreferences.manualSensitivity * 100).round()}%',
                onChanged: (value) async {
                  await _run(() async {
                    await YappaAudioPreferences.setAutomaticSensitivity(false);
                    await YappaAudioPreferences.setManualSensitivity(value);
                    await _restartMicMonitor();
                  });
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Green is comfortable, yellow means you are getting hot, and red means your mic is very loud. Keep the threshold marker above room noise but below normal speech.',
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Voice processing',
          subtitle:
              'Cleanup options for echo, noise, and automatic leveling.',
          child: Column(
            children: [
              SwitchListTile.adaptive(
                value: YappaAudioPreferences.echoCancellation,
                onChanged: (value) async {
                  await _run(() async {
                    await YappaAudioPreferences.setEchoCancellation(value);
                    await _restartMicMonitor();
                  });
                },
                contentPadding: EdgeInsets.zero,
                title: const Text('Echo cancellation'),
              ),
              SwitchListTile.adaptive(
                value: YappaAudioPreferences.noiseSuppression,
                onChanged: (value) async {
                  await _run(() async {
                    await YappaAudioPreferences.setNoiseSuppression(value);
                    await _restartMicMonitor();
                  });
                },
                contentPadding: EdgeInsets.zero,
                title: const Text('Noise suppression'),
              ),
              SwitchListTile.adaptive(
                value: YappaAudioPreferences.autoGainControl,
                onChanged: (value) async {
                  await _run(() async {
                    await YappaAudioPreferences.setAutoGainControl(value);
                    await _restartMicMonitor();
                  });
                },
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic gain control'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Live voice state',
          subtitle:
              'This shows whether the active voice session is healthy right now.',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _StatusPill(
                label: appState.voiceTransportInitialized
                    ? 'Transport ready'
                    : 'Not initialized',
                active: appState.voiceTransportInitialized,
              ),
              _StatusPill(
                label: appState.voiceTransportJoined
                    ? 'Joined voice'
                    : 'Not in voice',
                active: appState.voiceTransportJoined,
              ),
              _StatusPill(
                label: appState.voiceTransportMicrophoneReady
                    ? 'Mic ready'
                    : 'Mic not ready',
                active: appState.voiceTransportMicrophoneReady,
              ),
              _StatusPill(
                label: appState.voiceTransportRemoteAudioAttached
                    ? 'Remote audio attached'
                    : 'No remote audio',
                active: appState.voiceTransportRemoteAudioAttached,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoSettingsTab extends StatefulWidget {
  const _VideoSettingsTab();

  @override
  State<_VideoSettingsTab> createState() => _VideoSettingsTabState();
}

class _VideoSettingsTabState extends State<_VideoSettingsTab> {
  bool _saving = false;

  Future<void> _setBackend(YappaLinuxScreenShareBackend value) async {
    setState(() {
      _saving = true;
    });

    await YappaVideoPreferences.setLinuxScreenShareBackend(value);
    await YappaVideoPreferences.load();

    if (!mounted) {
      return;
    }

    setState(() {
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final backend = YappaVideoPreferences.linuxScreenShareBackend;
    final detectedSession = YappaVideoPreferences.detectedLinuxSessionType;
    final effectivePath = YappaVideoPreferences.effectiveLinuxScreenSharePath;
    final blockMessage = YappaVideoPreferences.linuxScreenShareBlockMessage();

    String backendSummary() {
      switch (backend) {
        case YappaLinuxScreenShareBackend.auto:
          return 'Yappa uses the native Linux share flow first and keeps an X11 fallback ready when needed.';
        case YappaLinuxScreenShareBackend.nativePortal:
          return 'Always use the native Linux screen capture path.';
        case YappaLinuxScreenShareBackend.x11Only:
          return 'Only allow screen sharing when the app is actually running in an X11 session, using the legacy X11 capture path.';
        case YappaLinuxScreenShareBackend.disableOnWayland:
          return 'Block screen sharing entirely when Yappa is running in Wayland.';
      }
    }

    return ListView(
      children: [
        Text(
          'Video',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Linux screen sharing can behave differently depending on whether the desktop session is Wayland or X11. This setting does not change your desktop session; it only changes how Yappa responds.',
          style: TextStyle(
            color: NewChatColors.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        _SettingsCard(
          title: 'Session detection',
          subtitle:
              'Yappa auto-detects the current Linux session every time screen share is started.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  const _StatusPill(
                    label: 'Linux build',
                    active: true,
                  ),
                  _StatusPill(
                    label: 'Detected: $detectedSession',
                    active: detectedSession != 'Unknown',
                  ),
                  _StatusPill(
                    label: effectivePath,
                    active: blockMessage == null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                detectedSession == 'Wayland'
                    ? 'Wayland uses the desktop portal chooser directly, so the system picker is expected to own the final share selection.'
                    : detectedSession == 'X11'
                        ? 'X11 now uses the native Linux share flow in Auto mode first, with a legacy X11 fallback only when Yappa needs it.'
                        : 'Yappa could not confidently detect the desktop session, so Auto will fall back to the safest built-in path.',
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Linux screen share backend',
          subtitle:
              'Pick how Yappa should behave before it attempts Linux screen capture.',
          headerTrailing: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ChoiceChip(
                    label: const Text('Auto'),
                    selected: backend == YappaLinuxScreenShareBackend.auto,
                    onSelected: _saving
                        ? null
                        : (_) => _setBackend(YappaLinuxScreenShareBackend.auto),
                  ),
                  ChoiceChip(
                    label: const Text('Native Linux capture'),
                    selected:
                        backend == YappaLinuxScreenShareBackend.nativePortal,
                    onSelected: _saving
                        ? null
                        : (_) => _setBackend(
                              YappaLinuxScreenShareBackend.nativePortal,
                            ),
                  ),
                  ChoiceChip(
                    label: const Text('X11 only'),
                    selected: backend == YappaLinuxScreenShareBackend.x11Only,
                    onSelected: _saving
                        ? null
                        : (_) => _setBackend(
                              YappaLinuxScreenShareBackend.x11Only,
                            ),
                  ),
                  ChoiceChip(
                    label: const Text('Disable on Wayland'),
                    selected:
                        backend == YappaLinuxScreenShareBackend.disableOnWayland,
                    onSelected: _saving
                        ? null
                        : (_) => _setBackend(
                              YappaLinuxScreenShareBackend.disableOnWayland,
                            ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                backendSummary(),
                style: TextStyle(
                  color: NewChatColors.textMuted,
                  height: 1.45,
                ),
              ),
              if (blockMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x221B2433),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x55FFB4BF)),
                  ),
                  child: Text(
                    blockMessage,
                    style: const TextStyle(
                      color: Color(0xFFFFC6CF),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'What this setting can and cannot do',
          subtitle:
              'This keeps the Linux behavior understandable instead of mysterious.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '• It can auto-detect Wayland or X11 and choose the safest Linux screen share path.',
                style: TextStyle(color: NewChatColors.textMuted, height: 1.45),
              ),
              const SizedBox(height: 8),
              Text(
                '• It can keep Auto mode on the native Linux chooser while still leaving an X11 fallback available when the portal path fails.',
                style: TextStyle(color: NewChatColors.textMuted, height: 1.45),
              ),
              const SizedBox(height: 8),
              Text(
                '• It cannot switch your KDE session between Wayland and X11 from inside Yappa.',
                style: TextStyle(color: NewChatColors.textMuted, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AccentChoiceChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _AccentChoiceChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? NewChatColors.surfaceSoft : NewChatColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? color : NewChatColors.outline,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _FontChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FontChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: NewChatColors.surfaceSoft,
      backgroundColor: NewChatColors.surface,
      side: BorderSide(
        color: selected ? NewChatColors.accentGlow : NewChatColors.outline,
      ),
      labelStyle: TextStyle(
        color: selected ? Colors.white : null,
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;
  final Widget? headerTrailing;

  const _SettingsCard({
    required this.title,
    this.subtitle = '',
    required this.child,
    this.expandChild = false,
    this.headerTrailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              if (headerTrailing != null) ...[
                const SizedBox(width: 12),
                headerTrailing!,
              ],
            ],
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(
                color: NewChatColors.textMuted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
          ] else
            const SizedBox(height: 12),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final bool active;

  const _StatusPill({
    required this.label,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: active ? const Color(0x1F2A5E40) : NewChatColors.panelAlt,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? NewChatColors.accentGlow : NewChatColors.outline,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: active ? Colors.white : NewChatColors.textMuted,
        ),
      ),
    );
  }
}

class _LevelBar extends StatelessWidget {
  final double value;
  final double peak;
  final double threshold;

  const _LevelBar({
    required this.value,
    required this.peak,
    required this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      decoration: BoxDecoration(
        color: NewChatColors.panelAlt,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final levelWidth = width * value.clamp(0.0, 1.0);
          final peakLeft = (width * peak.clamp(0.0, 1.0)).clamp(0.0, width - 2);
          final thresholdLeft =
              (width * threshold.clamp(0.0, 1.0)).clamp(0.0, width - 2);

          final greenEnd = width * 0.60;
          final yellowEnd = width * 0.82;

          return Stack(
            children: [
              Row(
                children: [
                  Container(
                    width: greenEnd,
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E5E3B),
                    ),
                  ),
                  Container(
                    width: yellowEnd - greenEnd,
                    decoration: const BoxDecoration(
                      color: Color(0xFF8A6A18),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF7C2525),
                      ),
                    ),
                  ),
                ],
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: levelWidth,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF00E676),
                      Color(0xFFFFD54F),
                      Color(0xFFFF5252),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Positioned(
                left: thresholdLeft,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFD28A),
                    borderRadius: BorderRadius.all(Radius.circular(999)),
                  ),
                ),
              ),
              Positioned(
                left: peakLeft,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(999)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LabeledSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? displayText;

  const _LabeledSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.displayText,
  });

  @override
  Widget build(BuildContext context) {
    final display = displayText ??
        (max == 360 ? value.round().toString() : '${(value * 100).round()}%');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(color: NewChatColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsPlaceholderTab extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;

  const _SettingsPlaceholderTab({
    required this.title,
    required this.description,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: NewChatColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: NewChatColors.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: NewChatColors.accentGlow),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: NewChatColors.textMuted,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoSettingsTab extends StatefulWidget {
  const _InfoSettingsTab();

  @override
  State<_InfoSettingsTab> createState() => _InfoSettingsTabState();
}

class _InfoSettingsTabState extends State<_InfoSettingsTab> {
  static const String _rawUrl =
      'https://raw.githubusercontent.com/CtrlAltForgot/Yappa/main/client_information.txt';

  late Future<_ClientInfoPayload> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  static const String _fallbackVersion = String.fromEnvironment(
    'YAPPA_VERSION',
    defaultValue: 'alpha 1.1',
  );
  static const String _fallbackBuild = String.fromEnvironment(
    'YAPPA_BUILD',
    defaultValue: '0317261606',
  );

  Future<_ClientInfoPayload> _load() async {
    String changelog;

    try {
      final response = await http
          .get(
            Uri.parse(_rawUrl),
            headers: const {
              'Accept': 'text/plain',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        changelog = response.body.trim();
        if (changelog.isEmpty) {
          changelog =
              'The remote changelog is currently empty. Add text to client_information.txt and it will appear here.';
        }
      } else {
        changelog =
            'Unable to load the remote changelog right now (HTTP ${response.statusCode}).';
      }
    } catch (_) {
      changelog =
          'Unable to reach the remote changelog right now. Later we can cache this on boot for offline viewing too.';
    }

    return _ClientInfoPayload(
      version: _fallbackVersion,
      buildNumber: _fallbackBuild,
      changelog: changelog,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ClientInfoPayload>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: NewChatColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: NewChatColors.outline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 42,
                    color: NewChatColors.warning,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Could not load client info',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NewChatColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.tonal(
                    onPressed: _refresh,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final data = snapshot.data!;
        final buildLabel = data.buildNumber.trim().isEmpty
            ? 'Unspecified'
            : data.buildNumber;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Info',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _InfoPill(label: 'Version', value: data.version),
                _InfoPill(label: 'Build', value: buildLabel),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _SettingsCard(
                title: 'Announcements and Changelog',
                expandChild: true,
                headerTrailing: OutlinedButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh'),
                ),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 360),
                  decoration: BoxDecoration(
                    color: NewChatColors.panelAlt,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: NewChatColors.outline),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                        child: SelectableText(
                          data.changelog,
                          style: const TextStyle(
                            height: 1.5,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ClientInfoPayload {
  final String version;
  final String buildNumber;
  final String changelog;

  const _ClientInfoPayload({
    required this.version,
    required this.buildNumber,
    required this.changelog,
  });
}

class _InfoPill extends StatelessWidget {
  final String label;
  final String value;

  const _InfoPill({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 14),
          children: [
            TextSpan(
              text: '$label  ',
              style: TextStyle(
                color: NewChatColors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
