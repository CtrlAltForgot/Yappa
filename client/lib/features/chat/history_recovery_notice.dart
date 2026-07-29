import 'package:flutter/material.dart';

enum HistoryRecoveryUiPhase {
  beginsOnThisDevice,
  waitingForExistingDevice,
  approvalRequired,
  transferring,
  readyToRecover,
  shared,
  recovered,
  failed,
}

class HistoryRecoveryDestination {
  final String deviceId;
  final String label;

  const HistoryRecoveryDestination({
    required this.deviceId,
    required this.label,
  });
}

class HistoryRecoveryUiState {
  final HistoryRecoveryUiPhase phase;
  final String? deviceLabel;
  final int? firstServerSequence;
  final int? lastServerSequence;
  final double? progress;
  final String? safeError;
  final List<HistoryRecoveryDestination> destinations;
  final bool canCancel;

  const HistoryRecoveryUiState({
    required this.phase,
    this.deviceLabel,
    this.firstServerSequence,
    this.lastServerSequence,
    this.progress,
    this.safeError,
    this.destinations = const [],
    this.canCancel = false,
  });

  String get message => switch (phase) {
    HistoryRecoveryUiPhase.beginsOnThisDevice =>
      'History begins when this device joined.',
    HistoryRecoveryUiPhase.waitingForExistingDevice =>
      'Waiting for one of your existing devices to approve history recovery.',
    HistoryRecoveryUiPhase.approvalRequired =>
      destinations.length > 1
          ? 'Share encrypted history with another enrolled device?'
          : 'Share encrypted history with ${deviceLabel ?? destinations.firstOrNull?.label ?? 'another device'}?',
    HistoryRecoveryUiPhase.transferring =>
      'Recovering encrypted history${_progressSuffix(progress)}',
    HistoryRecoveryUiPhase.readyToRecover =>
      'Encrypted history from ${deviceLabel ?? 'an existing device'} is ready.',
    HistoryRecoveryUiPhase.shared =>
      'Encrypted history through sequence ${lastServerSequence ?? '—'} is ready for ${deviceLabel ?? 'the selected device'}.',
    HistoryRecoveryUiPhase.recovered =>
      'Recovered through sequence ${lastServerSequence ?? '—'}.',
    HistoryRecoveryUiPhase.failed =>
      safeError?.trim().isNotEmpty == true
          ? safeError!.trim()
          : 'Encrypted history recovery failed.',
  };

  String? get actionLabel => switch (phase) {
    HistoryRecoveryUiPhase.approvalRequired => 'Review transfer',
    HistoryRecoveryUiPhase.readyToRecover => 'Recover history',
    HistoryRecoveryUiPhase.failed => 'Try again',
    _ => null,
  };

  static String _progressSuffix(double? value) {
    if (value == null || !value.isFinite) return '…';
    final percent = (value.clamp(0, 1) * 100).round();
    return '… $percent%';
  }
}

class HistoryRecoveryNotice extends StatelessWidget {
  final HistoryRecoveryUiState state;
  final Future<void> Function(String? destinationDeviceId)? onAction;
  final Future<void> Function()? onCancel;

  const HistoryRecoveryNotice({
    super.key,
    required this.state,
    this.onAction,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final failed = state.phase == HistoryRecoveryUiPhase.failed;
    final completed = state.phase == HistoryRecoveryUiPhase.recovered;
    final color = failed
        ? const Color(0xFF8F4B52)
        : completed
        ? const Color(0xFF31584C)
        : const Color(0xFF4A496D);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF171720),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            failed
                ? Icons.error_outline_rounded
                : completed
                ? Icons.history_toggle_off_rounded
                : Icons.history_rounded,
            color: failed ? const Color(0xFFFFA8B1) : const Color(0xFFB9B4EF),
            size: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.message,
              style: const TextStyle(
                color: Color(0xFFE4E1F5),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (state.phase == HistoryRecoveryUiPhase.transferring) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: state.progress,
              ),
            ),
          ],
          if (state.actionLabel != null && onAction != null) ...[
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => _confirmAndRun(context),
              child: Text(state.actionLabel!),
            ),
          ],
          if (state.canCancel && onCancel != null) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: () => _confirmCancel(context),
              child: const Text('Stop transfer'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmAndRun(BuildContext context) async {
    if (state.phase == HistoryRecoveryUiPhase.failed) {
      await onAction?.call(null);
      return;
    }
    final approving = state.phase == HistoryRecoveryUiPhase.approvalRequired;
    final first = state.firstServerSequence;
    final last = state.lastServerSequence;
    final range = first == null || last == null
        ? 'the available encrypted history'
        : 'messages $first through $last';
    String? selectedDestination = state.destinations.length == 1
        ? state.destinations.single.deviceId
        : null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            approving
                ? 'Share encrypted history?'
                : 'Recover encrypted history?',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                approving
                    ? 'Send $range directly to the selected device? '
                          'The server relays encrypted data and cannot read it.'
                    : 'Verify and merge $range from '
                          '${state.deviceLabel ?? 'your existing device'}? '
                          'Nothing is shown until the complete transfer is authenticated.',
              ),
              if (approving && state.destinations.length > 1) ...[
                const SizedBox(height: 14),
                for (final destination in state.destinations)
                  ListTile(
                    leading: Icon(
                      selectedDestination == destination.deviceId
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                    ),
                    title: Text(destination.label),
                    selected: selectedDestination == destination.deviceId,
                    onTap: () {
                      setDialogState(
                        () => selectedDestination = destination.deviceId,
                      );
                    },
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  approving &&
                      state.destinations.isNotEmpty &&
                      selectedDestination == null
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(approving ? 'Share history' : 'Recover history'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) await onAction?.call(selectedDestination);
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop encrypted-history transfer?'),
        content: const Text(
          'Yappa will remove the unfinished encrypted relay copy and the '
          'protected local retry. Existing messages on both devices stay unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep trying'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop transfer'),
          ),
        ],
      ),
    );
    if (accepted == true) await onCancel?.call();
  }
}
