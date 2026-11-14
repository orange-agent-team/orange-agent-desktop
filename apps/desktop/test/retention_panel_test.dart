import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/retention_controller.dart';
import 'package:orange_desktop/retention_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

// Transport substitutions only; actual filesystem/SQLite and drain are Rust tests.
class RetentionFixture implements RetentionCommands {
  static const run = RunSummary(
    runId: 'run',
    workspaceId: 'workspace',
    phase: 'completed',
    steps: 2,
    invocations: 1,
    active: false,
  );
  static const workspace = WorkspaceView(
    workspaceId: 'workspace',
    displayPath: '/owned',
    permissionVersion: '3',
    permissionActive: false,
    sessionAccess: false,
  );
  static const access = RetentionAccessView(
    sessionToken: 'selection',
    runId: 'run',
    operationId: 'operation',
    workspaceId: 'workspace',
    displayDirectory: '/owned',
  );
  static const missing = RecoveryFileStatusView(
    kind: 'missing',
    reviewedOriginalInode: false,
    matchesOriginalContent: false,
    matchesResultContent: false,
  );
  int approvals = 0, queries = 0, releases = 0;
  bool committed = false,
      loseReply = false,
      failRelease = false,
      wrongSnapshot = false;
  String? lookupOverride;
  Completer<RecoverySelection?>? choiceGate;
  Completer<String>? approveGate;
  final choosing = Completer<void>(), approving = Completer<void>();
  RetentionInspectionView view() => RetentionInspectionView(
    sessionToken: 'selection',
    runId: wrongSnapshot ? 'another-run' : 'run',
    operationId: 'operation',
    path: 'note.txt',
    executionState: 'succeeded',
    staged: missing,
    original: missing,
    resourceActiveRecords: committed ? 0 : 1,
    resourceActiveReservedBytes: committed ? '0' : '1400000',
    ownerArchiveRecords: committed ? 1 : 0,
    ownerArchiveReservedBytes: committed ? '1400000' : '0',
    ownerArchiveLimitBytes: '268435456',
    ownerArchiveRecordLimit: 1000,
    archivedReviewId: committed ? 'review' : null,
    changedSinceArchival: committed ? false : null,
  );
  @override
  Future<RunPage> runs(String? before) async => const RunPage(runs: [run]);
  @override
  Future<List<String>> operations(String run, String? before) async => [
    'operation',
  ];
  @override
  Future<List<WorkspaceView>> workspaces() async => [workspace];
  @override
  Future<RecoverySelection?> choose() async {
    choosing.complete();
    return choiceGate == null
        ? const RecoverySelection('selection', '/owned')
        : await choiceGate!.future;
  }

  @override
  Future<RetentionAccessView> authorize(
    RunSummary run,
    String op,
    WorkspaceView workspace,
    RecoverySelection selected,
  ) async => access;
  @override
  Future<RetentionInspectionView> inspect(String token) async => view();
  @override
  Future<RetentionReviewView> prepare(String token, String request) async =>
      RetentionReviewView(
        sessionToken: 'selection',
        operationId: 'operation',
        reviewId: 'review',
        digest: 'a' * 64,
        path: 'note.txt',
        staged: missing,
        original: missing,
        archiveReservedBytes: '1400000',
        expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
      );
  @override
  Future<String> approve(RetentionReviewView review) async {
    approvals++;
    approving.complete();
    if (approveGate != null) return approveGate!.future;
    committed = true;
    if (loseReply) throw StateError('lost reply after commit');
    return 'review';
  }

  @override
  Future<String?> outcome(String run, String op) async {
    queries++;
    return lookupOverride ?? (committed ? 'review' : null);
  }

  @override
  Future<void> release(String token) async {
    releases++;
    if (failRelease) throw StateError('drain not confirmed');
  }
}

Future<RetentionController> ready(RetentionFixture f) async {
  final c = RetentionController(f);
  await c.refresh();
  await c.selectRun(RetentionFixture.run);
  await c.chooseAndInspect();
  return c;
}

void main() {
  testWidgets(
    'archive requires exact preview and explicit confirmation; quota is not disk usage',
    (tester) async {
      final f = RetentionFixture();
      final c = await ready(f);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RetentionPanel(controller: c, supported: true),
            ),
          ),
        ),
      );
      await tester.tap(find.text('保留原件管理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会释放磁盘空间'), findsOneWidget);
      expect(f.approvals, 0);
      await tester.ensureVisible(find.text('生成归档预览'));
      await tester.tap(find.text('生成归档预览'));
      await tester.pumpAndSettle();
      expect(f.approvals, 0);
      await tester.ensureVisible(find.text('确认本次原地归档'));
      await tester.tap(find.text('确认本次原地归档'));
      await tester.pumpAndSettle();
      expect(f.approvals, 1);
      expect(find.textContaining('已登记原地保留，文件未移动'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  test('selection and preview never archive; exact explicit approval changes accounting', () async {
    final f = RetentionFixture();
    final c = await ready(f);
    expect(f.approvals, 0);
    await c.prepare();
    expect(f.approvals, 0);
    expect(c.review!.digest, 'a' * 64);
    await c.approve();
    expect(f.approvals, 1);
    expect(f.queries, 0);
    expect(c.snapshot!.ownerArchiveRecords, 1);
    expect(c.notice, contains('文件未移动或删除'));
    await c.approve();
    expect(f.approvals, 1);
    await c.stop();
    c.dispose();
  });
  test(
    'lost successful reply queries once and never repeats approval',
    () async {
      final f = RetentionFixture()..loseReply = true;
      final c = await ready(f);
      await c.prepare();
      await c.approve();
      expect(f.approvals, 1);
      expect(f.queries, 1);
      expect(c.notice, isNotNull);
      expect(c.error, isNull);
      await c.stop();
      c.dispose();
    },
  );
  test(
    'a different archived review cannot be shown as this approval succeeding',
    () async {
      final f = RetentionFixture()
        ..loseReply = true
        ..lookupOverride = 'another-review';
      final c = await ready(f);
      await c.prepare();
      await c.approve();
      expect(c.notice, isNull);
      expect(c.snapshot, isNull);
      expect(c.review, isNull);
      expect(c.error, contains('未自动重发'));
      expect(f.approvals, 1);
      expect(f.queries, 1);
      await c.stop();
      c.dispose();
    },
  );
  test(
    'stop during approval hides late success without restoring a scope',
    () async {
      final f = RetentionFixture()..approveGate = Completer<String>();
      final c = await ready(f);
      await c.prepare();
      final approving = c.approve();
      await f.approving.future;
      await c.stop();
      f.approveGate!.complete('review');
      await approving;
      expect(c.notice, isNull);
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(f.queries, 0);
      expect(f.releases, 1);
      c.dispose();
    },
  );
  test(
    'a late picker callback is released without authorization or display',
    () async {
      final f = RetentionFixture()
        ..choiceGate = Completer<RecoverySelection?>();
      final c = RetentionController(f);
      await c.selectRun(RetentionFixture.run);
      final choosing = c.chooseAndInspect();
      await f.choosing.future;
      await c.stop();
      f.choiceGate!.complete(const RecoverySelection('selection', '/owned'));
      await choosing;
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(f.releases, 1);
      c.dispose();
    },
  );
  test('unconfirmed release is visible and retried before forgetting native ownership', () async {
    final f = RetentionFixture()..failRelease = true;
    final c = await ready(f);
    await expectLater(c.stop(), throwsStateError);
    expect(c.error, contains('释放尚未确认'));
    expect(c.snapshot, isNull);
    f.failRelease = false;
    await c.stop();
    expect(f.releases, 2);
    c.dispose();
  });
  test(
    'cross-run observation is rejected and its selection released',
    () async {
      final f = RetentionFixture()..wrongSnapshot = true;
      final c = await ready(f);
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(c.error, isNotNull);
      expect(f.releases, 1);
      c.dispose();
    },
  );
}
