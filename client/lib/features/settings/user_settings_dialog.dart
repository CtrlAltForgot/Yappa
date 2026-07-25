import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/api_client.dart';
import '../../models/member_model.dart';
import '../../shared/avatar_image.dart';

Future<void> showUserSettingsDialog({
  required BuildContext context,
  required AppState appState,
}) async {
  final controller = TextEditingController(text: appState.currentDisplayName);
  Future<List<DeviceSession>> sessionsFuture = appState
      .fetchCurrentDeviceSessions();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      String? statusMessage;
      bool isSaving = false;

      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final member = appState.currentUserMemberForSelectedServer;
          final yuid = appState.currentYuid;

          Future<void> revokeSession(DeviceSession session) async {
            setDialogState(() {
              isSaving = true;
              statusMessage = null;
            });
            try {
              await appState.revokeDeviceSession(session);
              if (!session.current) {
                sessionsFuture = appState.fetchCurrentDeviceSessions();
              }
              setDialogState(() {
                statusMessage = session.current
                    ? 'This device was logged out.'
                    : '${session.deviceName} was logged out.';
              });
              if (session.current && dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            } catch (error) {
              setDialogState(() {
                statusMessage = error.toString().replaceFirst(
                  'Exception: ',
                  '',
                );
              });
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => isSaving = false);
              }
            }
          }

          Future<void> saveProfile() async {
            setDialogState(() {
              isSaving = true;
              statusMessage = null;
            });
            final error = await appState.updateCurrentUserProfile(
              displayName: controller.text,
            );
            setDialogState(() {
              isSaving = false;
              statusMessage = error ?? 'Profile updated for this server.';
            });
          }

          Future<void> chooseAvatar() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
              withData: true,
            );
            final picked = result?.files.single;
            final bytes =
                picked?.bytes ??
                (picked?.path != null
                    ? await File(picked!.path!).readAsBytes()
                    : null);
            if (bytes == null || bytes.isEmpty) return;
            if (bytes.length > 1024 * 1024) {
              setDialogState(() {
                statusMessage = 'Please choose an image under 1 MB for now.';
              });
              return;
            }
            final extension = (picked?.extension ?? 'png').toLowerCase();
            final mime = extension == 'jpg' ? 'jpeg' : extension;
            final dataUri = 'data:image/$mime;base64,${base64Encode(bytes)}';
            setDialogState(() {
              isSaving = true;
              statusMessage = null;
            });
            final error = await appState.updateCurrentUserAvatar(
              avatarSource: dataUri,
            );
            setDialogState(() {
              isSaving = false;
              statusMessage =
                  error ?? 'Profile picture updated for this server.';
            });
          }

          Future<void> removeAvatar() async {
            setDialogState(() {
              isSaving = true;
              statusMessage = null;
            });
            final error = await appState.updateCurrentUserAvatar(
              avatarSource: null,
            );
            setDialogState(() {
              isSaving = false;
              statusMessage =
                  error ?? 'Profile picture removed for this server.';
            });
          }

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 120,
              vertical: 60,
            ),
            backgroundColor: Colors.transparent,
            child: Container(
              width: 760,
              height: 560,
              decoration: BoxDecoration(
                color: NewChatColors.panel,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 40,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'User Settings',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Display name and profile picture are saved per server. Your YUID stays the same everywhere.',
                      style: TextStyle(color: NewChatColors.textMuted),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _AvatarPanel(
                            member: member,
                            onChooseAvatar: isSaving ? null : chooseAvatar,
                            onRemoveAvatar: isSaving ? null : removeAvatar,
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: ListView(
                              children: [
                                _ProfileCard(
                                  title: 'Profile',
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Display name',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller: controller,
                                        maxLength: 32,
                                        decoration: const InputDecoration(
                                          hintText: 'Enter a display name',
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Username: ${appState.currentUsername}',
                                        style: TextStyle(
                                          color: NewChatColors.textMuted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _ProfileCard(
                                  title: 'YUID',
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: SelectableText(
                                          yuid,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          Clipboard.setData(
                                            ClipboardData(text: yuid),
                                          );
                                          setDialogState(() {
                                            statusMessage = 'YUID copied.';
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.copy_rounded,
                                          size: 16,
                                        ),
                                        label: const Text('Copy'),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _ProfileCard(
                                  title: 'Signed-in devices',
                                  child: FutureBuilder<List<DeviceSession>>(
                                    future: sessionsFuture,
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState !=
                                          ConnectionState.done) {
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      }
                                      if (snapshot.hasError) {
                                        return Text(
                                          'Could not load sessions: ${snapshot.error}',
                                          style: const TextStyle(
                                            color: Color(0xFFFFB4BF),
                                          ),
                                        );
                                      }
                                      final sessions =
                                          snapshot.data ?? const [];
                                      return Column(
                                        children: [
                                          for (final session in sessions)
                                            ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              leading: Icon(
                                                session.current
                                                    ? Icons.devices_rounded
                                                    : Icons
                                                          .desktop_windows_rounded,
                                              ),
                                              title: Text(
                                                session.current
                                                    ? '${session.deviceName} (this device)'
                                                    : session.deviceName,
                                              ),
                                              subtitle: Text(
                                                _sessionDescription(session),
                                                style: TextStyle(
                                                  color:
                                                      NewChatColors.textMuted,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              trailing: TextButton(
                                                onPressed: isSaving
                                                    ? null
                                                    : () => revokeSession(
                                                        session,
                                                      ),
                                                child: Text(
                                                  session.current
                                                      ? 'Log out'
                                                      : 'Revoke',
                                                ),
                                              ),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                if (statusMessage != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    statusMessage!,
                                    style: TextStyle(
                                      color:
                                          statusMessage!.toLowerCase().contains(
                                                'updated',
                                              ) ||
                                              statusMessage!
                                                  .toLowerCase()
                                                  .contains('copied') ||
                                              statusMessage!
                                                  .toLowerCase()
                                                  .contains('removed')
                                          ? const Color(0xFF7DFFAF)
                                          : const Color(0xFFFFB4BF),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: isSaving
                              ? null
                              : () => Navigator.of(dialogContext).pop(),
                          child: const Text('Close'),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          onPressed: isSaving ? null : saveProfile,
                          icon: isSaving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded, size: 18),
                          label: const Text('Save profile'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

String _sessionDescription(DeviceSession session) {
  final lastSeen = session.lastSeenAt?.toLocal();
  final expires = session.expiresAt?.toLocal();
  final parts = <String>[];
  if (lastSeen != null) {
    parts.add('Last active ${_shortDate(lastSeen)}');
  }
  if (expires != null) {
    parts.add('Expires ${_shortDate(expires)}');
  }
  return parts.isEmpty ? 'Session details unavailable' : parts.join(' • ');
}

String _shortDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

class _AvatarPanel extends StatelessWidget {
  final Member? member;
  final VoidCallback? onChooseAvatar;
  final VoidCallback? onRemoveAvatar;

  const _AvatarPanel({
    required this.member,
    required this.onChooseAvatar,
    required this.onRemoveAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = member?.name ?? '';
    final initial =
        (displayName.isNotEmpty ? displayName.characters.first : '?')
            .toUpperCase();
    return SizedBox(
      width: 220,
      child: _ProfileCard(
        title: 'Profile picture',
        child: Column(
          children: [
            Container(
              width: 148,
              height: 148,
              decoration: BoxDecoration(
                color: NewChatColors.panelAlt,
                borderRadius: BorderRadius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: _DialogAvatar(
                source: member?.avatarUrl,
                fallbackInitial: initial,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onChooseAvatar,
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('Choose picture'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: onRemoveAvatar,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Remove picture'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogAvatar extends StatelessWidget {
  final String? source;
  final String fallbackInitial;

  const _DialogAvatar({required this.source, required this.fallbackInitial});

  @override
  Widget build(BuildContext context) {
    return AvatarImage(
      source: source,
      fallbackInitial: fallbackInitial,
      size: 148,
      animate: true,
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _ProfileCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NewChatColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NewChatColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
