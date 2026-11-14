import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:orange_desktop/export_restoration_controller.dart';
import 'package:orange_desktop/export_restoration_panel.dart';
import 'package:orange_desktop/export_retirement_controller.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

import 'export_retirement_test.dart' show RetirementFixture;

class RestorationFixture implements ExportRestorationCommands {
  static const parentId = '11111111-1111-4111-8111-111111111111';
  static const restoreId = '22222222-2222-4222-8222-222222222222';
  static const read = ExportInspectionAccessView(
    sessionToken: 'read',
    runId: 'run',
    operationId: 'op',
    exportId: 'export',
    displayDirectory: '/output',
  );
  static final parent = ExportRetirementOutcomeView(
    retirementId: parentId,
    exportId: 'export',
    reviewDigest: 'a' * 64,
    state: 'retained',
  );
  static final file = ExportObservedFileView(
    kind: 'regular',
    bytes: '100',
    sha256: 'b' * 64,
    matchesApprovedArtifact: true,
    validExportDocument: true,
  );
  static const missing = ExportObservedFileView(
    kind: 'missing',
    matchesApprovedArtifact: false,
    validExportDocument: false,
  );
  int approvals = 0, releases = 0, selections = 0, prepares = 0;
  bool loseReply = false,
      wrongReceipt = false,
      wrongScope = false,
      failRelease = false;
  String fileName = 'recovered.orange-retained.json', state = 'prepared';
  Completer<RecoverySelection?>? picker;
  Completer<ExportRestorationOutcomeView>? approval;
  @override
  Future<RecoverySelection?> choose() async => picker == null
      ? RecoverySelection('restore-${++selections}', '/output')
      : await picker!.future;
  @override
  Future<ExportRestorationAccessView> authorize(
    String reader,
    RecoverySelection s,
  ) async => ExportRestorationAccessView(
    sessionToken: s.token,
    readSessionToken: reader,
    runId: 'run',
    operationId: 'op',
    exportId: 'export',
    displayDirectory: s.directory,
  );
  @override
  Future<ExportRestorationReviewView> prepare(
    String token,
    String key,
    String retirementId,
    String name,
  ) async {
    prepares++;
    fileName = name;
    return ExportRestorationReviewView(
      sessionToken: token,
      restorationId: restoreId,
      retirementId: wrongScope
          ? '33333333-3333-4333-8333-333333333333'
          : retirementId,
      exportId: 'export',
      digest: 'c' * 64,
      fileName: name,
      source: file,
      expiresAt: PlatformInt64Util.from(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
      ),
    );
  }

  ExportRestorationOutcomeView get record => ExportRestorationOutcomeView(
    restorationId: restoreId,
    retirementId: parentId,
    exportId: 'export',
    reviewDigest: 'c' * 64,
    fileName: fileName,
    state: state,
  );
  @override
  Future<ExportRestorationOutcomeView> approve(
    String token,
    String id,
    String digest,
  ) async {
    approvals++;
    state = 'succeeded';
    if (approval != null) return approval!.future;
    if (loseReply) throw StateError('lost after commit');
    if (wrongReceipt) {
      return ExportRestorationOutcomeView(
        restorationId: id,
        retirementId: parentId,
        exportId: 'export',
        reviewDigest: 'd' * 64,
        fileName: fileName,
        state: 'succeeded',
      );
    }
    return record;
  }

  @override
  Future<List<ExportRestorationOutcomeView>> list(
    ExportInspectionAccessView read,
    String parent,
    String? before,
  ) async => [record];
  @override
  Future<ExportRestorationInspectionView> inspect(
    String reader,
    String id,
  ) async => ExportRestorationInspectionView(
    sessionToken: reader,
    restorationId: id,
    retirementId: parentId,
    exportId: 'export',
    fileName: fileName,
    recordedState: state,
    target: file,
    staged: missing,
  );
  @override
  Future<void> release(String token) async {
    releases++;
    if (failRelease) throw StateError('drain unconfirmed');
  }
}

void main() {
  testWidgets(
    'copy requires selected name and exact confirmation; unknown inspection does not repair outcome',
    (tester) async {
      final f = RestorationFixture();
      final actual = ExportRestorationController(f);
      await actual.open(RestorationFixture.read, RestorationFixture.parent);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ExportRestorationPanel(controller: actual),
            ),
          ),
        ),
      );
      expect(find.text('确认创建恢复副本'), findsNothing);
      await tester.enterText(
        find.byType(TextFormField),
        'chosen.orange-retained.json',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目录并预览恢复副本'));
      await tester.pumpAndSettle();
      expect(f.approvals, 0);
      expect(actual.review!.fileName, 'chosen.orange-retained.json');
      await tester.ensureVisible(find.text('确认创建恢复副本'));
      await tester.tap(find.text('确认创建恢复副本'));
      await tester.pumpAndSettle();
      expect(f.approvals, 1);
      expect(f.releases, 1);
      expect(actual.notice, '恢复副本已创建，保留区原件仍保留。');
      expect(actual.review, isNull);
      f.state = 'unknown';
      await actual.refresh();
      await actual.inspect(actual.records.single);
      await tester.pumpAndSettle();
      expect(find.text('恢复记录仍待核对，内容匹配不会自动确认成功。'), findsOneWidget);
      await actual.approve();
      expect(f.approvals, 1);
      await actual.close();
      actual.dispose();
    },
  );
  test(
    'invalid names and mismatched parent previews never reach approval',
    () async {
      final f = RestorationFixture();
      final actual = ExportRestorationController(f);
      await actual.open(RestorationFixture.read, RestorationFixture.parent);
      for (final name in [
        '../escape.orange-retained.json',
        '.orange-agent-tmp-x',
        'plain.txt',
      ]) {
        actual.setFileName(name);
        await actual.prepare();
        expect(f.prepares, 0);
      }
      actual.setFileName('safe.orange-retained.json');
      f.wrongScope = true;
      await actual.prepare();
      expect(actual.review, isNull);
      expect(actual.error, isNotNull);
      await actual.approve();
      expect(f.approvals, 0);
      expect(f.releases, 1);
      await actual.close();
      actual.dispose();
    },
  );
  test('lost replies or invalid receipt preserve uncertainty and never retry approval', () async {
    for (final wrong in [false, true]) {
      final f = RestorationFixture()
        ..loseReply = !wrong
        ..wrongReceipt = wrong;
      final c = ExportRestorationController(f);
      await c.open(RestorationFixture.read, RestorationFixture.parent);
      await c.prepare();
      await c.approve();
      expect(c.notice, isNull);
      expect(c.error, isNotNull);
      expect(c.records.single.state, 'succeeded');
      await c.approve();
      expect(f.approvals, 1);
      await c.close();
      c.dispose();
    }
  });
  test(
    'late picker and dispatch responses do not revive closed restoration state',
    () async {
      final f = RestorationFixture()..picker = Completer<RecoverySelection?>();
      final c = ExportRestorationController(f);
      await c.open(RestorationFixture.read, RestorationFixture.parent);
      final work = c.prepare();
      await Future<void>.delayed(Duration.zero);
      await c.close();
      f.picker!.complete(const RecoverySelection('late', '/output'));
      await work;
      expect(c.review, isNull);
      expect(f.approvals, 0);
      expect(f.releases, 1);
      f.picker = null;
      f.approval = Completer<ExportRestorationOutcomeView>();
      await c.open(RestorationFixture.read, RestorationFixture.parent);
      await c.prepare();
      final dispatched = c.approve();
      await Future<void>.delayed(Duration.zero);
      await c.close();
      f.approval!.complete(f.record);
      await dispatched;
      expect(c.notice, isNull);
      expect(c.records, isEmpty);
      expect(c.parent, isNull);
      expect(f.approvals, 1);
      c.dispose();
    },
  );
  test(
    'closing parent retires child proof and retries unconfirmed OS release',
    () async {
      final retire = RetirementFixture(), restore = RestorationFixture();
      final parent = ExportRetirementController(
        retire,
        restorationCommands: restore,
      );
      await parent.attach(RetirementFixture.read, RetirementFixture.snapshot);
      await parent.openRestoration(RestorationFixture.parent);
      await parent.restoration!.prepare();
      expect(parent.restoration!.review, isNotNull);
      restore.failRelease = true;
      await expectLater(parent.close(), throwsStateError);
      expect(parent.restoration!.review, isNull);
      await parent.restoration!.approve();
      expect(restore.approvals, 0);
      restore.failRelease = false;
      await parent.close();
      expect(restore.releases, 2);
      parent.dispose();
    },
  );
}
