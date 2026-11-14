import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/export_panel.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/retention_controller.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

import 'retention_panel_test.dart' show RetentionFixture;

// UI transport fixture only. Native Host tests exercise real files and leases.
class ExportFixture implements ExportCommands {
  int approvals = 0, queries = 0, releases = 0;
  bool loseReply = false,
      failRelease = false,
      wrongLookup = false,
      unknown = false,
      wrongPreview = false,
      failHistory = false;
  final events = <String>[];
  Completer<RecoverySelection?>? chooseGate;
  Completer<ExportOutcomeView>? approveGate;
  final choosing = Completer<void>(), approving = Completer<void>();
  ExportOutcomeView? committed;
  String get digest => 'd' * 64;
  @override
  Future<RecoverySelection?> choose() async {
    choosing.complete();
    return chooseGate == null
        ? const RecoverySelection('destination', '/output')
        : await chooseGate!.future;
  }

  @override
  Future<ExportAccessView> authorize(
    RetentionAccessView reader,
    RecoverySelection selected,
  ) async => const ExportAccessView(
    sessionToken: 'destination',
    readSessionToken: 'selection',
    runId: 'run',
    operationId: 'operation',
    workspaceId: 'workspace',
    displayDirectory: '/output',
  );
  @override
  Future<ExportReviewView> prepare(
    String token,
    String request,
    String fileName,
    String choice,
  ) async => ExportReviewView(
    sessionToken: token,
    readSessionToken: 'selection',
    runId: wrongPreview ? 'another-run' : 'run',
    operationId: 'operation',
    exportId: 'export',
    digest: digest,
    sourcePath: 'note.txt',
    fileName: fileName,
    choice: choice,
    entries: [
      ExportFileView(
        role: 'original',
        bytes: '4',
        sha256: 'a' * 64,
        matchesReviewedOriginal: true,
        matchesReviewedResult: false,
        reviewedOriginalInode: true,
      ),
    ],
    artifactBytes: '1024',
    artifactSha256: 'b' * 64,
    expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
  );
  @override
  Future<ExportOutcomeView> approve(ExportReviewView review) async {
    approvals++;
    approving.complete();
    if (approveGate != null) return approveGate!.future;
    committed = ExportOutcomeView(
      exportId: 'export',
      reviewDigest: digest,
      state: unknown ? 'unknown' : 'succeeded',
    );
    if (loseReply) throw StateError('lost reply');
    return committed!;
  }

  @override
  Future<ExportOutcomeView?> outcome(
    String run,
    String op,
    String exportId,
  ) async {
    queries++;
    return wrongLookup
        ? ExportOutcomeView(
            exportId: 'other-export',
            reviewDigest: digest,
            state: 'succeeded',
          )
        : committed;
  }

  @override
  Future<List<ExportOutcomeView>> records(
    String run,
    String op,
    String? before,
  ) async {
    if (failHistory) throw StateError('history unavailable');
    return committed == null ? [] : [committed!];
  }

  @override
  Future<void> release(String token) async {
    releases++;
    events.add('destination');
    if (failRelease) throw StateError('drain unconfirmed');
  }
}

class SourceFixture extends RetentionFixture {
  SourceFixture(this.destination);
  final ExportFixture destination;
  @override
  Future<void> release(String token) async {
    destination.events.add('source');
    return super.release(token);
  }
}

Future<RetentionController> ready(ExportFixture fixture) async {
  final c = RetentionController(
    SourceFixture(fixture),
    exportCommands: fixture,
  );
  await c.refresh();
  await c.selectRun(RetentionFixture.run);
  await c.chooseAndInspect();
  await c.chooseExportDestination();
  return c;
}

void main() {
  testWidgets(
    'destination and preview never write; only explicit confirmation exports',
    (tester) async {
      final f = ExportFixture();
      final c = await ready(f);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ExportPanel(controller: c)),
          ),
        ),
      );
      expect(find.textContaining('不是加密备份'), findsOneWidget);
      expect(f.approvals, 0);
      await tester.ensureVisible(find.text('生成导出预览'));
      await tester.tap(find.text('生成导出预览'));
      await tester.pumpAndSettle();
      expect(c.exportReview, isNotNull);
      expect(f.approvals, 0);
      expect(find.textContaining('1024'), findsOneWidget);
      await tester.ensureVisible(find.text('确认创建这个导出文件'));
      await tester.tap(find.text('确认创建这个导出文件'));
      await tester.pumpAndSettle();
      expect(f.approvals, 1);
      expect(c.exportNotice, contains('原件未删除'));
      await c.approveExport();
      expect(f.approvals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.stop();
      expect(f.events, ['destination', 'source']);
      c.dispose();
    },
  );
  test('lost reply queries exactly once and never repeats approval', () async {
    final f = ExportFixture()..loseReply = true;
    final c = await ready(f);
    await c.prepareExport();
    await c.approveExport();
    expect(f.approvals, 1);
    expect(f.queries, 1);
    expect(c.exportOutcome!.state, 'succeeded');
    expect(c.error, isNull);
    await c.stop();
    c.dispose();
  });
  test('different export receipt cannot confirm this approval', () async {
    final f = ExportFixture()
      ..loseReply = true
      ..wrongLookup = true;
    final c = await ready(f);
    await c.prepareExport();
    await c.approveExport();
    expect(c.exportNotice, isNull);
    expect(c.exportOutcome, isNull);
    expect(c.error, contains('未确认'));
    expect(f.approvals, 1);
    await c.stop();
    c.dispose();
  });
  test('unknown outcome is visible without retry or deletion', () async {
    final f = ExportFixture()..unknown = true;
    final c = await ready(f);
    await c.prepareExport();
    await c.approveExport();
    expect(c.exportOutcome!.state, 'unknown');
    expect(c.exportNotice, isNull);
    expect(c.error, contains('待核对'));
    expect(f.approvals, 1);
    await c.stop();
    c.dispose();
  });
  test(
    'stop drops destination before source and hides a late success',
    () async {
      final f = ExportFixture()..approveGate = Completer<ExportOutcomeView>();
      final c = await ready(f);
      await c.prepareExport();
      final pending = c.approveExport();
      await f.approving.future;
      await c.stop();
      f.approveGate!.complete(
        ExportOutcomeView(
          exportId: 'export',
          reviewDigest: f.digest,
          state: 'succeeded',
        ),
      );
      await pending;
      expect(c.exportNotice, isNull);
      expect(c.exportOutcome, isNull);
      expect(c.exportAccess, isNull);
      expect(f.queries, 0);
      expect(f.events, ['destination', 'source']);
      c.dispose();
    },
  );
  test(
    'late native destination choice is closed after source shutdown',
    () async {
      final f = ExportFixture()..chooseGate = Completer<RecoverySelection?>();
      final c = RetentionController(SourceFixture(f), exportCommands: f);
      await c.selectRun(RetentionFixture.run);
      await c.chooseAndInspect();
      final choice = c.chooseExportDestination();
      await f.choosing.future;
      await c.stop();
      f.chooseGate!.complete(const RecoverySelection('destination', '/output'));
      await choice;
      expect(c.exportAccess, isNull);
      expect(f.releases, 1);
      expect(c.access, isNull);
      c.dispose();
    },
  );
  test('changing requested file name invalidates displayed approval', () async {
    final f = ExportFixture();
    final c = await ready(f);
    await c.prepareExport();
    expect(c.exportReview, isNotNull);
    c.setExportFileName('new.orange-retained.json');
    await c.approveExport();
    expect(f.approvals, 0);
    expect(c.exportReview, isNull);
    await c.stop();
    c.dispose();
  });
  test('mismatched preview is rejected before an approval', () async {
    final f = ExportFixture()..wrongPreview = true;
    final c = await ready(f);
    await c.prepareExport();
    expect(c.exportReview, isNull);
    expect(c.error, isNotNull);
    expect(f.approvals, 0);
    await c.stop();
    c.dispose();
  });
  test('unconfirmed destination release remains retryable', () async {
    final f = ExportFixture()..failRelease = true;
    final c = await ready(f);
    await c.prepareExport();
    await expectLater(c.closeExport(), throwsStateError);
    expect(c.exportReview, isNull);
    expect(c.error, contains('释放尚未确认'));
    f.failRelease = false;
    await c.closeExport();
    expect(f.releases, 2);
    expect(c.access, isNotNull);
    await c.stop();
    c.dispose();
  });
  test('a confirmed receipt is retained when history refresh fails', () async {
    final f = ExportFixture();
    final c = await ready(f);
    await c.prepareExport();
    f.failHistory = true;
    await c.approveExport();
    expect(c.exportOutcome!.state, 'succeeded');
    expect(c.exportNotice, isNotNull);
    expect(c.error, contains('导出已确认'));
    await c.stop();
    c.dispose();
  });
}
