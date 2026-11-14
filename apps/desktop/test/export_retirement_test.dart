import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/export_retirement_controller.dart';
import 'package:orange_desktop/export_retirement_panel.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

class RetirementFixture implements ExportRetirementCommands {
  static const id = '11111111-1111-4111-8111-111111111111';
  static const read = ExportInspectionAccessView(
    sessionToken: 'read',
    runId: 'run',
    operationId: 'op',
    exportId: 'export',
    displayDirectory: '/output',
  );
  static final file = ExportObservedFileView(
    kind: 'regular',
    bytes: '100',
    sha256: 'b' * 64,
    matchesApprovedArtifact: true,
    validExportDocument: true,
  );
  static final snapshot = ExportInspectionView(
    sessionToken: 'read',
    runId: 'run',
    operationId: 'op',
    exportId: 'export',
    reviewDigest: 'a' * 64,
    recordedState: 'unknown',
    fileName: 'proof.orange-retained.json',
    target: file,
    staged: const ExportObservedFileView(
      kind: 'missing',
      matchesApprovedArtifact: false,
      validExportDocument: false,
    ),
  );
  int approvals = 0, releases = 0, chosen = 0;
  bool lostReply = false, wrongDigest = false, releaseFailure = false;
  String state = 'prepared';
  Completer<RecoverySelection?>? picker;
  Completer<ExportRetirementOutcomeView>? approval;
  @override
  Future<RecoverySelection?> choose() async => picker == null
      ? RecoverySelection('write-${++chosen}', '/output')
      : await picker!.future;
  @override
  Future<ExportRetirementAccessView> authorize(
    String reader,
    RecoverySelection s,
  ) async => ExportRetirementAccessView(
    sessionToken: s.token,
    readSessionToken: reader,
    runId: 'run',
    operationId: 'op',
    exportId: 'export',
    displayDirectory: s.directory,
  );
  @override
  Future<ExportRetirementReviewView> prepare(
    String token,
    String key,
    String choice,
  ) async => ExportRetirementReviewView(
    sessionToken: token,
    retirementId: id,
    exportId: 'export',
    digest: 'c' * 64,
    choice: choice,
    fileName: 'proof.orange-retained.json',
    observed: file,
    expiresAt: PlatformInt64Util.from(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
    ),
  );
  ExportRetirementOutcomeView get record => ExportRetirementOutcomeView(
    retirementId: id,
    exportId: 'export',
    reviewDigest: 'c' * 64,
    state: state,
  );
  @override
  Future<ExportRetirementOutcomeView> approve(
    String token,
    String id,
    String digest,
  ) async {
    approvals++;
    state = 'retained';
    if (approval != null) return approval!.future;
    if (lostReply) throw StateError('reply lost');
    return ExportRetirementOutcomeView(
      retirementId: id,
      exportId: 'export',
      reviewDigest: (wrongDigest ? 'd' : 'c') * 64,
      state: state,
    );
  }

  @override
  Future<List<ExportRetirementOutcomeView>> list(
    ExportInspectionAccessView read,
    String? before,
  ) async => [record];
  @override
  Future<ExportRetirementInspectionView> inspect(
    String reader,
    String id,
  ) async => ExportRetirementInspectionView(
    sessionToken: reader,
    retirementId: id,
    exportId: 'export',
    recordedState: state,
    choice: 'target',
    capsuleBound: true,
    retained: file,
  );
  @override
  Future<void> release(String token) async {
    releases++;
    if (releaseFailure) throw StateError('not drained');
  }
}

void main() {
  testWidgets(
    'separate selection and exact confirmation retain data; unknown observation stays unknown',
    (tester) async {
      final f = RetirementFixture();
      final actual = ExportRetirementController(f);
      await actual.attach(RetirementFixture.read, RetirementFixture.snapshot);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ExportRetirementPanel(controller: actual),
            ),
          ),
        ),
      );
      expect(find.text('确认移入保留区'), findsNothing);
      await tester.tap(find.text('选择目录并预览移出目标'));
      await tester.pumpAndSettle();
      expect(f.approvals, 0);
      expect(actual.review, isNotNull);
      await tester.ensureVisible(find.text('确认移入保留区'));
      await tester.tap(find.text('确认移入保留区'));
      await tester.pumpAndSettle();
      expect(f.approvals, 1);
      expect(f.releases, 1);
      expect(actual.review, isNull);
      expect(actual.notice, '已移入保留区，数据仍保留。');
      await actual.approve();
      expect(f.approvals, 1);
      f.state = 'unknown';
      await actual.refresh();
      await actual.inspect(actual.records.single);
      await tester.pumpAndSettle();
      expect(find.text('记录仍待核对，匹配结果不会自动确认成功。'), findsOneWidget);
      await actual.close();
      actual.dispose();
    },
  );
  test('lost reply and mismatched receipt query metadata without replay or success notice', () async {
    for (final wrong in [false, true]) {
      final f = RetirementFixture()
        ..lostReply = !wrong
        ..wrongDigest = wrong;
      final c = ExportRetirementController(f);
      await c.attach(RetirementFixture.read, RetirementFixture.snapshot);
      await c.prepare('target');
      await c.approve();
      expect(c.error, isNotNull);
      expect(c.notice, isNull);
      expect(c.records.single.state, 'retained');
      expect(c.review, isNull);
      expect(f.approvals, 1);
      await c.approve();
      expect(f.approvals, 1);
      await c.close();
      c.dispose();
    }
  });
  test('late picker and late approval cannot revive closed scopes', () async {
    final f = RetirementFixture()..picker = Completer<RecoverySelection?>();
    final c = ExportRetirementController(f);
    await c.attach(RetirementFixture.read, RetirementFixture.snapshot);
    final work = c.prepare('target');
    await Future<void>.delayed(Duration.zero);
    await c.close();
    f.picker!.complete(const RecoverySelection('late', '/output'));
    await work;
    expect(c.review, isNull);
    expect(f.approvals, 0);
    expect(f.releases, 1);
    f.picker = null;
    f.approval = Completer<ExportRetirementOutcomeView>();
    await c.attach(RetirementFixture.read, RetirementFixture.snapshot);
    await c.prepare('target');
    final dispatch = c.approve();
    await Future<void>.delayed(Duration.zero);
    await c.close();
    f.approval!.complete(f.record);
    await dispatch;
    expect(c.notice, isNull);
    expect(c.read, isNull);
    expect(c.records, isEmpty);
    expect(f.approvals, 1);
    c.dispose();
  });
  test(
    'unconfirmed native release is retained for explicit close retry',
    () async {
      final f = RetirementFixture();
      final actual = ExportRetirementController(f);
      await actual.attach(RetirementFixture.read, RetirementFixture.snapshot);
      await actual.prepare('target');
      f.releaseFailure = true;
      await expectLater(actual.close(), throwsStateError);
      expect(actual.error, contains('释放尚未确认'));
      expect(actual.review, isNull);
      f.releaseFailure = false;
      await actual.close();
      expect(f.releases, 2);
      actual.dispose();
    },
  );
}
