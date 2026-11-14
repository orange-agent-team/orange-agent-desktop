import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/export_inspection_controller.dart';
import 'package:orange_desktop/export_inspection_panel.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/retention_controller.dart';

import 'retention_panel_test.dart' show RetentionFixture;

import 'package:orange_desktop/src/rust/api/host.dart';

class InspectionFixture implements ExportInspectionCommands {
  final choosing = Completer<void>(), reading = Completer<void>();
  Completer<RecoverySelection?>? choiceGate;
  Completer<ExportInspectionView>? viewGate;
  int releases = 0, authorizations = 0;
  bool failRelease = false;
  String state = 'unknown', digest = 'a' * 64, operation = 'op';
  static const missing = ExportObservedFileView(
    kind: 'missing',
    matchesApprovedArtifact: false,
    validExportDocument: false,
  );
  ExportOutcomeView get record => ExportOutcomeView(
    exportId: 'export',
    reviewDigest: 'a' * 64,
    state: 'unknown',
  );
  ExportInspectionView snapshot() => ExportInspectionView(
    sessionToken: 'check',
    runId: 'run',
    operationId: operation,
    exportId: 'export',
    reviewDigest: digest,
    recordedState: state,
    fileName: 'proof.orange-retained.json',
    target: ExportObservedFileView(
      kind: 'regular',
      bytes: '100',
      sha256: 'b' * 64,
      matchesApprovedArtifact: true,
      validExportDocument: true,
    ),
    staged: missing,
  );
  @override
  Future<RecoverySelection?> choose() async {
    choosing.complete();
    return choiceGate == null
        ? const RecoverySelection('check', '/output')
        : await choiceGate!.future;
  }

  @override
  Future<ExportInspectionAccessView> authorize(
    String run,
    String operation,
    String exportId,
    RecoverySelection choice,
  ) async {
    authorizations++;
    this.operation = operation;
    return ExportInspectionAccessView(
      sessionToken: choice.token,
      runId: run,
      operationId: operation,
      exportId: exportId,
      displayDirectory: choice.directory,
    );
  }

  @override
  Future<ExportInspectionView> inspect(String token) async {
    reading.complete();
    return viewGate == null ? snapshot() : await viewGate!.future;
  }

  @override
  Future<void> release(String token) async {
    releases++;
    if (failRelease) throw StateError('unconfirmed drain');
  }
}

void main() {
  testWidgets(
    'matching file retains unknown state and offers only readonly inspection',
    (tester) async {
      final f = InspectionFixture();
      final inspected = ExportInspectionController(f);
      await inspected.open('run', 'op', f.record);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExportInspectionPanel(controller: inspected)),
        ),
      );
      expect(find.text('记录仍待核对。匹配结果只描述当前文件。'), findsOneWidget);
      expect(find.text('目标：内容匹配已批准的数据包'), findsOneWidget);
      expect(find.textContaining('确认成功'), findsNothing);
      expect(find.textContaining('删除文件'), findsNothing);
      expect(inspected.view!.recordedState, 'unknown');
      await tester.tap(find.text('结束导出检查'));
      await tester.pumpAndSettle();
      expect(inspected.view, isNull);
      expect(f.releases, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      inspected.dispose();
    },
  );
  test(
    'a terminal unknown record cannot be promoted by a returned snapshot',
    () async {
      final f = InspectionFixture()..state = 'succeeded';
      final c = ExportInspectionController(f);
      await c.open('run', 'op', f.record);
      expect(c.view, isNull);
      expect(c.error, isNotNull);
      expect(f.releases, 1);
      c.dispose();
    },
  );
  test('wrong immutable review digest is rejected', () async {
    final f = InspectionFixture()..digest = 'c' * 64;
    final c = ExportInspectionController(f);
    await c.open('run', 'op', f.record);
    expect(c.view, isNull);
    expect(f.releases, 1);
    c.dispose();
  });
  test('late native choice is released without authorization', () async {
    final f = InspectionFixture()..choiceGate = Completer<RecoverySelection?>();
    final c = ExportInspectionController(f);
    final opening = c.open('run', 'op', f.record);
    await f.choosing.future;
    await c.close();
    f.choiceGate!.complete(const RecoverySelection('check', '/output'));
    await opening;
    expect(f.authorizations, 0);
    expect(f.releases, 1);
    expect(c.view, isNull);
    c.dispose();
  });
  test('closed reader never displays a late file snapshot', () async {
    final f = InspectionFixture()..viewGate = Completer<ExportInspectionView>();
    final c = ExportInspectionController(f);
    final opening = c.open('run', 'op', f.record);
    await f.reading.future;
    await c.close();
    f.viewGate!.complete(f.snapshot());
    await opening;
    expect(c.view, isNull);
    expect(c.access, isNull);
    expect(f.releases, 1);
    c.dispose();
  });
  test('failed native release retains ownership for retry', () async {
    final f = InspectionFixture();
    final c = ExportInspectionController(f);
    await c.open('run', 'op', f.record);
    f.failRelease = true;
    await expectLater(c.close(), throwsStateError);
    expect(c.view, isNull);
    expect(c.error, contains('释放尚未确认'));
    f.failRelease = false;
    await c.close();
    expect(f.releases, 2);
    c.dispose();
  });
  test(
    'parent closure releases independent reader without opening source access',
    () async {
      final source = RetentionFixture(), inspection = InspectionFixture();
      final c = RetentionController(source, inspectionCommands: inspection);
      await c.selectRun(RetentionFixture.run);
      c.exportRecords = [inspection.record];
      await c.inspectExportRecord(inspection.record);
      expect(c.exportInspection!.view, isNotNull);
      expect(c.access, isNull);
      expect(source.choosing.isCompleted, isFalse);
      await c.stop();
      expect(c.exportInspection!.view, isNull);
      expect(inspection.releases, 1);
      expect(source.releases, 0);
      c.dispose();
    },
  );
}
