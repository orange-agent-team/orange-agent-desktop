import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/recovery_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

import 'recovery_panel_test.dart' show RecoveryFixture;

// UI protocol fixtures only; actual file effects and durable recovery are
// exercised by the Rust/native suites, never inferred from these values.
class WriteFixture extends RecoveryFixture implements WritingRecoveryCommands {
  int approvals = 0, lookups = 0, writeAuthorizations = 0;
  String? approvedDigest;
  bool lostReply = false, uncertain = false;
  bool changedDecision = false;
  RecoveryOutcomeView? committed;
  Completer<RecoverySelection?>? writePicker;
  final writePickerStarted = Completer<void>(),
      prepareStarted = Completer<void>();
  Completer<RecoveryDecisionView>? prepareGate;
  RecoveryDecisionView review([String choice = 'keep_current_target']) =>
      RecoveryDecisionView(
        readSessionToken: 'selection-1',
        writeSessionToken: 'write-selection-1',
        recoveryId: 'recovery-1',
        digest: 'd' * 64,
        choice: choice,
        inspection: view(),
      );
  @override
  Future<RecoverySelection?> chooseWrite() async {
    events.add('choose-write');
    if (!writePickerStarted.isCompleted) writePickerStarted.complete();
    return writePicker == null
        ? const RecoverySelection('write-selection-1', '/fixture')
        : await writePicker!.future;
  }

  @override
  Future<RecoveryWriteAccessView> authorizeWrite(
    RecoveryInspectionAccessView read,
    RecoverySelection selection,
  ) async {
    writeAuthorizations++;
    return const RecoveryWriteAccessView(
      sessionToken: 'write-selection-1',
      readSessionToken: 'selection-1',
      runId: 'run-1',
      operationId: 'operation-1',
      workspaceId: 'workspace-1',
      displayDirectory: '/fixture',
    );
  }

  @override
  Future<RecoveryDecisionView> prepare(
    String reader,
    String writer,
    String request,
    String choice,
  ) async {
    events.add('prepare');
    expect(reader, 'selection-1');
    expect(writer, 'write-selection-1');
    if (!prepareStarted.isCompleted) prepareStarted.complete();
    return prepareGate == null ? review(choice) : await prepareGate!.future;
  }

  @override
  Future<RecoveryOutcomeView> approve(RecoveryDecisionView value) async {
    approvals++;
    approvedDigest = value.digest;
    if (uncertain) {
      throw StateError('explicit missing receipt fixture; effects unknown');
    }
    committed = RecoveryOutcomeView(
      runId: 'run-1',
      operationId: 'operation-1',
      originalExecutionState: 'unknown',
      recoveryId: 'recovery-1',
      choice: changedDecision
          ? 'publish_staged_to_missing_target'
          : 'keep_current_target',
    );
    if (lostReply) {
      throw StateError('explicit response loss after committed decision');
    }
    return committed!;
  }

  @override
  Future<RecoveryOutcomeView> outcome(String run, String operation) async {
    lookups++;
    return committed ??
        const RecoveryOutcomeView(
          runId: 'run-1',
          operationId: 'operation-1',
          originalExecutionState: 'unknown',
        );
  }

  @override
  Future<void> releaseWrite(String token) async {
    events.add('released-write:$token');
  }
}

Future<RecoveryController> ready(WriteFixture f) async {
  final c = RecoveryController(f);
  await c.selectRun(RecoveryFixture.run);
  await c.chooseAndInspect();
  return c;
}

void main() {
  testWidgets(
    'write consent and actual decision preview precede one exact approval',
    (tester) async {
      final f = WriteFixture();
      final c = await ready(f);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecoveryPanel(controller: c, supported: true),
            ),
          ),
        ),
      );
      expect(find.text('批准这个处理决定'), findsNothing);
      await tester.ensureVisible(find.text('单独授权处理这次改动'));
      await tester.tap(find.text('单独授权处理这次改动'));
      await tester.pumpAndSettle();
      expect(f.writeAuthorizations, 1);
      expect(f.approvals, 0);
      expect(find.text('批准这个处理决定'), findsNothing);
      await tester.ensureVisible(find.text('核对保留当前文件'));
      await tester.tap(find.text('核对保留当前文件'));
      await tester.pumpAndSettle();
      expect(f.approvals, 0);
      expect(find.text('待批准决定：保留当前文件'), findsOneWidget);
      await tester.ensureVisible(find.text('批准这个处理决定'));
      await tester.tap(find.text('批准这个处理决定'));
      await tester.pumpAndSettle();
      expect(f.approvals, 1);
      expect(f.approvedDigest, 'd' * 64);
      expect(c.outcome?.originalExecutionState, 'unknown');
      expect(find.textContaining('旧任务不会继续'), findsOneWidget);
      expect(
        f.events.where((e) => e == 'released-write:write-selection-1').length,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      await c.stop();
      c.dispose();
    },
  );
  test(
    'lost reply queries committed outcome and never resends approval',
    () async {
      final f = WriteFixture()..lostReply = true;
      final c = await ready(f);
      await c.chooseWrite();
      await c.prepareDecision('keep_current_target');
      await c.approveDecision();
      expect(f.approvals, 1);
      expect(f.lookups, 1);
      expect(c.outcome?.recoveryId, 'recovery-1');
      expect(c.notice, contains('本次处理已记录'));
      await c.approveDecision();
      expect(f.approvals, 1);
      await c.stop();
      c.dispose();
    },
  );
  test(
    'missing outcome remains uncertain without fake success or replay',
    () async {
      final f = WriteFixture()..uncertain = true;
      final c = await ready(f);
      await c.chooseWrite();
      await c.prepareDecision('keep_current_target');
      await c.approveDecision();
      expect(c.outcome, isNull);
      expect(c.snapshot, isNull);
      expect(c.error, contains('尚未确认'));
      expect(c.decision, isNull);
      expect(c.writeAccess, isNull);
      await c.approveDecision();
      expect(f.approvals, 1);
      expect(f.lookups, 1);
      await c.stop();
      c.dispose();
    },
  );
  test('late write picker cannot recreate authority after stop', () async {
    final f = WriteFixture()..writePicker = Completer<RecoverySelection?>();
    final c = await ready(f);
    final pending = c.chooseWrite();
    await f.writePickerStarted.future;
    await c.stop();
    f.writePicker!.complete(
      const RecoverySelection('write-selection-1', '/fixture'),
    );
    await pending;
    expect(f.writeAuthorizations, 0);
    expect(c.writeAccess, isNull);
    expect(
      f.events.where((e) => e == 'released-write:write-selection-1').length,
      1,
    );
    c.dispose();
  });
  test('late decision preview is discarded after scope revocation', () async {
    final f = WriteFixture()..prepareGate = Completer<RecoveryDecisionView>();
    final c = await ready(f);
    await c.chooseWrite();
    final pending = c.prepareDecision('keep_current_target');
    await f.prepareStarted.future;
    await c.stop();
    f.prepareGate!.complete(f.review());
    await pending;
    expect(c.decision, isNull);
    expect(c.snapshot, isNull);
    expect(f.approvals, 0);
    c.dispose();
  });
  test('wrong decision observation cannot enable approval', () async {
    final f = WriteFixture();
    final c = await ready(f);
    await c.chooseWrite();
    f.operation = 'other-operation';
    await c.prepareDecision('keep_current_target');
    expect(c.decision, isNull);
    expect(c.error, isNotNull);
    await c.approveDecision();
    expect(f.approvals, 0);
    await c.stop();
    c.dispose();
  });
  test('a changed choice under the same decision identity is not displayed as success', () async {
    final f = WriteFixture()..changedDecision = true;
    final c = await ready(f);
    await c.chooseWrite();
    await c.prepareDecision('keep_current_target');
    await c.approveDecision();
    expect(c.outcome, isNull);
    expect(c.notice, isNull);
    expect(c.error, isNotNull);
    expect(f.approvals, 1);
    await c.stop();
    c.dispose();
  });
}
