import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/features/chat/history_recovery_notice.dart';

void main() {
  testWidgets('requires explicit confirmation before sharing history', (
    tester,
  ) async {
    var approvals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HistoryRecoveryNotice(
            state: const HistoryRecoveryUiState(
              phase: HistoryRecoveryUiPhase.approvalRequired,
              deviceLabel: 'Windows device ••••wxyz',
              firstServerSequence: 1,
              lastServerSequence: 5000,
            ),
            onAction: (_) async {
              approvals += 1;
            },
          ),
        ),
      ),
    );

    expect(
      find.text('Share encrypted history with Windows device ••••wxyz?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Review transfer'));
    await tester.pumpAndSettle();
    expect(find.text('Share encrypted history?'), findsOneWidget);
    expect(
      find.textContaining('server relays encrypted data and cannot read it'),
      findsOneWidget,
    );
    expect(approvals, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Share history'));
    await tester.pumpAndSettle();
    expect(approvals, 1);
  });

  testWidgets(
    'reports honest waiting, progress, completion, and failure states',
    (tester) async {
      Future<void> pump(HistoryRecoveryUiState state) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HistoryRecoveryNotice(state: state)),
        ),
      );

      await pump(
        const HistoryRecoveryUiState(
          phase: HistoryRecoveryUiPhase.waitingForExistingDevice,
        ),
      );
      expect(
        find.textContaining('Waiting for one of your existing'),
        findsOneWidget,
      );

      await pump(
        const HistoryRecoveryUiState(
          phase: HistoryRecoveryUiPhase.transferring,
          progress: 0.42,
        ),
      );
      expect(find.text('Recovering encrypted history… 42%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await pump(
        const HistoryRecoveryUiState(
          phase: HistoryRecoveryUiPhase.recovered,
          lastServerSequence: 5000,
        ),
      );
      expect(find.text('Recovered through sequence 5000.'), findsOneWidget);

      await pump(
        const HistoryRecoveryUiState(
          phase: HistoryRecoveryUiPhase.failed,
          safeError: 'Recovery failed authentication. No history was changed.',
        ),
      );
      expect(find.textContaining('No history was changed'), findsOneWidget);
      expect(find.textContaining('/home/'), findsNothing);
    },
  );
}
