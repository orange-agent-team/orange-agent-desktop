import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/recovery_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

// Explicit UI transport substitute. Actual SQLite/files/revocation are tested
// in Rust; these cases prove UI scheduling and do not certify native pickers.
class RecoveryFixture implements RecoveryCommands {
  static const run = RunSummary(
    runId: 'run-1',
    workspaceId: 'workspace-1',
    phase: 'recovery_required',
    steps: 1,
    invocations: 1,
    active: false,
  );
  static const workspace = WorkspaceView(
    workspaceId: 'workspace-1',
    displayPath: '/fixture',
    permissionVersion: '2',
    permissionActive: false,
    sessionAccess: false,
  );
  final events = <String>[];
  final chooseStarted = Completer<void>(),
      authorizeStarted = Completer<void>(),
      inspectStarted = Completer<void>();
  Completer<RecoverySelection?>? chooseGate;
  Completer<RecoveryInspectionAccessView>? authorizeGate;
  Completer<RecoveryInspectionView>? inspectGate;
  bool failRelease = false;
  String operation = 'operation-1';
  String state = 'unknown';
  String targetDigest = 'a' * 64;
  RecoveryInspectionAccessView access() => const RecoveryInspectionAccessView(
    sessionToken: 'selection-1',
    runId: 'run-1',
    operationId: 'operation-1',
    workspaceId: 'workspace-1',
    displayDirectory: '/fixture',
  );
  RecoveryFileStatusView regular(bool original) => RecoveryFileStatusView(
    kind: 'regular',
    bytes: '4',
    sha256: original ? 'b' * 64 : targetDigest,
    securitySha256: 'c' * 64,
    reviewedOriginalInode: original,
    matchesOriginalContent: original,
    matchesResultContent: !original,
  );
  RecoveryInspectionView view() => RecoveryInspectionView(
    runId: 'run-1',
    operationId: operation,
    path: 'note.txt',
    executionState: state,
    lastDurableStage: 'published',
    target: regular(false),
    staged: const RecoveryFileStatusView(
      kind: 'missing',
      reviewedOriginalInode: false,
      matchesOriginalContent: false,
      matchesResultContent: false,
    ),
    original: regular(true),
  );
  @override
  Future<RunPage> runs(String? before) async {
    events.add('runs:$before');
    return const RunPage(runs: [run], nextCursor: '10');
  }

  @override
  Future<List<String>> operations(String run) async {
    events.add('operations:$run');
    return ['operation-1'];
  }

  @override
  Future<List<WorkspaceView>> workspaces() async => [workspace];
  @override
  Future<RecoverySelection?> choose() async {
    events.add('choose');
    if (!chooseStarted.isCompleted) chooseStarted.complete();
    return chooseGate == null
        ? const RecoverySelection('selection-1', '/fixture')
        : await chooseGate!.future;
  }

  @override
  Future<RecoveryInspectionAccessView> authorize(
    RunSummary run,
    String operation,
    WorkspaceView workspace,
    RecoverySelection selection,
  ) async {
    events.add('authorize');
    if (!authorizeStarted.isCompleted) authorizeStarted.complete();
    expect(workspace.permissionVersion, '2');
    expect(workspace.permissionActive, isFalse);
    return authorizeGate == null ? access() : await authorizeGate!.future;
  }

  @override
  Future<RecoveryInspectionView> inspect(String token) async {
    events.add('inspect');
    if (!inspectStarted.isCompleted) inspectStarted.complete();
    return inspectGate == null ? view() : await inspectGate!.future;
  }

  @override
  Future<void> release(String token) async {
    events.add('release-attempt:$token');
    if (failRelease) throw StateError('explicit unconfirmed drain fixture');
    events.add('released:$token');
  }
}

void main() {
  testWidgets(
    'inspection needs explicit selection and never claims the edit completed',
    (tester) async {
      final f = RecoveryFixture();
      final controller = RecoveryController(f);
      await controller.refresh();
      await controller.selectRun(RecoveryFixture.run);
      expect(f.events, isNot(contains('choose')));
      expect(controller.snapshot, isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecoveryPanel(controller: controller, supported: true),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择目录进行恢复检查'));
      await tester.pumpAndSettle();
      expect(find.text('原修改记录仍待核对'), findsOneWidget);
      expect(find.text('恢复完成'), findsNothing);
      expect(find.textContaining('文件："note.txt"'), findsOneWidget);
      expect(f.events.where((e) => e == 'authorize').length, 1);
      await tester.ensureVisible(find.text('结束恢复检查'));
      await tester.tap(find.text('结束恢复检查'));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件："note.txt"'), findsNothing);
      expect(f.events.where((e) => e == 'released:selection-1').length, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  test(
    'late native picker is released without creating file authority',
    () async {
      final f = RecoveryFixture()..chooseGate = Completer<RecoverySelection?>();
      final c = RecoveryController(f);
      await c.selectRun(RecoveryFixture.run);
      final pending = c.chooseAndInspect();
      await f.chooseStarted.future;
      await c.stop();
      f.chooseGate!.complete(
        const RecoverySelection('selection-1', '/fixture'),
      );
      await pending;
      expect(f.events, isNot(contains('authorize')));
      expect(c.snapshot, isNull);
      expect(f.events.where((e) => e == 'released:selection-1').length, 1);
      c.dispose();
    },
  );
  test(
    'late authorization cannot restore a closed inspection or release twice',
    () async {
      final f = RecoveryFixture()
        ..authorizeGate = Completer<RecoveryInspectionAccessView>();
      final c = RecoveryController(f);
      await c.selectRun(RecoveryFixture.run);
      final pending = c.chooseAndInspect();
      await f.authorizeStarted.future;
      await c.stop();
      f.authorizeGate!.complete(f.access());
      await pending;
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(f.events, isNot(contains('inspect')));
      expect(f.events.where((e) => e == 'released:selection-1').length, 1);
      c.dispose();
    },
  );
  test('workspace stopping clears late file observations', () async {
    final f = RecoveryFixture()
      ..inspectGate = Completer<RecoveryInspectionView>();
    final c = RecoveryController(f);
    await c.selectRun(RecoveryFixture.run);
    final pending = c.chooseAndInspect();
    await f.inspectStarted.future;
    c.workspaceStopping('workspace-1');
    f.inspectGate!.complete(f.view());
    await pending;
    expect(c.snapshot, isNull);
    expect(c.access, isNull);
    expect(f.events.where((e) => e == 'released:selection-1').length, 1);
    c.dispose();
  });
  test(
    'wrong operation, malformed digest and invented success are rejected',
    () async {
      for (final fault in ['operation', 'digest', 'state']) {
        final f = RecoveryFixture();
        if (fault == 'operation') f.operation = 'other-operation';
        if (fault == 'digest') f.targetDigest = 'invalid';
        if (fault == 'state') f.state = 'succeeded';
        final c = RecoveryController(f);
        await c.selectRun(RecoveryFixture.run);
        await c.chooseAndInspect();
        expect(c.snapshot, isNull);
        expect(c.error, isNotNull);
        expect(f.events, contains('released:selection-1'));
        c.dispose();
      }
    },
  );
  test('unconfirmed cleanup stays visible and can be retried', () async {
    final f = RecoveryFixture();
    final controller = RecoveryController(f);
    await controller.selectRun(RecoveryFixture.run);
    await controller.chooseAndInspect();
    f.failRelease = true;
    await expectLater(controller.stop(), throwsStateError);
    expect(controller.snapshot, isNull);
    expect(controller.error, contains('释放尚未确认'));
    expect(f.events, isNot(contains('released:selection-1')));
    f.failRelease = false;
    await controller.stop();
    expect(f.events.where((e) => e == 'released:selection-1').length, 1);
    controller.dispose();
  });
}
