import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/retention_controller.dart';
import 'package:orange_desktop/retention_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';
import 'native_host_test.dart' as helpers;

class LostExportReply extends NativeExportCommands {
  LostExportReply(super.handle);
  int approvals = 0, lookups = 0;
  bool loseReply = true;
  @override
  Future<ExportOutcomeView> approve(ExportReviewView review) async {
    approvals++;
    final value = await super.approve(review);
    if (loseReply) {
      loseReply = false;
      throw StateError('owned export reply lost after commit');
    }
    return value;
  }

  @override
  Future<ExportOutcomeView?> outcome(String run, String op, String id) {
    lookups++;
    return super.outcome(run, op, id);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets(
    'native export confirms exact file, reconciles lost replies and preserves unknown receipt failures',
    (tester) async {
      final private = await Directory.systemTemp.createTemp(
        'orange-retention-host-',
      );
      final workspace = await Directory.systemTemp.createTemp(
        'orange-retention-work-',
      );
      final output = await Directory.systemTemp.createTemp(
        'orange-export-output-',
      );
      final destinationReleased = Completer<void>();
      var destinationSelected = false;
      final sentinel =
          'RETENTION_OWNED_${DateTime.now().microsecondsSinceEpoch}';
      final source = await File('${workspace.path}/proof.txt')
          .writeAsString(sentinel);
      String? handle;
      LocalModelFixture? fixture;
      RetentionController? controller;
      bool passed = false;
      Directory? detachedWorkspace;
      final inspectionReleased = Completer<void>();
      var inspectionSelections = 0;
      var retirementReleaseConfirmed = false;
      var restorationSelections = 0, restorationReleases = 0;
      final released = Completer<void>();
      const channel = MethodChannel('orange_agent/platform');
      try {
        var host = await helpers.reopenHost(private.path);
        handle = host.handle;
        fixture = await LocalModelFixture.start(
          private,
          sentinel,
          editAfterRead: true,
        );
        final read = await authorizeWorkspace(
          handle: handle,
          requestId: 'retention-normal-read',
          selectedDirectory: workspace.path,
        );
        final edit = await authorizeEditingAccess(
          handle: handle,
          workspaceId: read.workspaceId,
          requestId: 'retention-normal-edit',
          selectedDirectory: workspace.path,
        );
        await connectLocalModel(
          handle: handle,
          selectedDirectory: fixture.root.path,
        );
        var run = await startEditingRun(
          handle: handle,
          workspaceId: read.workspaceId,
          requestId: 'retention-native-run',
          prompt: 'Read and edit proof.txt',
          editing: RunPermissionSelection(
            consentId: edit.consentId,
            permissionVersion: edit.permissionVersion,
          ),
          userQuestions: false,
        );
        Future<AgentRunView> step() => advanceRun(
          handle: handle!,
          runId: run.runId,
          expectedRevision: run.revision,
        );
        run = await step();
        expect(run.pending.single.toolName, 'read_file');
        run = await approveTool(
          handle: handle,
          runId: run.runId,
          operationId: run.pending.single.operationId,
          expectedDigest: run.pending.single.argumentDigest,
        );
        run = await step();
        run = await step();
        final operation = run.pending.single.operationId;
        expect(run.pending.single.toolName, 'apply_patch');
        final editPreview = await previewEditingTool(
          handle: handle,
          runId: run.runId,
          operationId: operation,
        );
        run = await approveEditingTool(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          previewDigest: editPreview.previewDigest,
        );
        run = await step();
        run = await step();
        expect(run.phase, 'completed');
        expect(await source.readAsString(), '${sentinel}_EDITED');
        expect(await workspace.list().length, 2);
        await closeHost(handle: handle);
        host = await helpers.reopenHost(private.path);
        handle = host.handle;
        expect(
          (await listWorkspaces(
            handle: handle,
            includeRevoked: true,
          )).every((w) => !w.sessionAccess),
          isTrue,
        );
        final history = (await listRuns(
          handle: handle,
          limit: 10,
        )).runs.singleWhere((r) => r.runId == run.runId);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'chooseExportInspectionDirectory') {
              return {
                'selectionId':
                    'native-independent-export-check-${++inspectionSelections}',
                'path': output.path,
              };
            }
            if (call.method == 'releaseExportInspectionSelection') {
              await expectLater(
                inspectExportFiles(
                  handle: handle!,
                  sessionToken:
                      (call.arguments as Map)['selectionId'] as String,
                ),
                throwsA(
                  isA<BridgeError>().having(
                    (e) => e.code,
                    'code',
                    'EXPORT_INSPECTION_CLOSED',
                  ),
                ),
              );
              if (!inspectionReleased.isCompleted) {
                inspectionReleased.complete();
              }
              return null;
            }
            if (call.method == 'chooseExportRestorationDirectory') {
              return {
                'selectionId': 'native-restore-${++restorationSelections}',
                'path': output.path,
              };
            }
            if (call.method == 'releaseExportRestorationSelection') {
              await expectLater(
                prepareExportRestoration(
                  handle: handle!,
                  sessionToken:
                      (call.arguments as Map)['selectionId'] as String,
                  requestId: 'late-restore',
                  retirementId: 'not-used',
                  fileName: 'late.orange-retained.json',
                ),
                throwsA(
                  isA<BridgeError>().having(
                    (e) => e.code,
                    'code',
                    'EXPORT_RESTORATION_CLOSED',
                  ),
                ),
              );
              restorationReleases++;
              return null;
            }
            if (call.method == 'chooseExportRetirementDirectory') {
              return {
                'selectionId': 'native-retirement-write',
                'path': output.path,
              };
            }
            if (call.method == 'releaseExportRetirementSelection') {
              await expectLater(
                prepareExportRetirement(
                  handle: handle!,
                  sessionToken: 'native-retirement-write',
                  requestId: 'late-retirement',
                  choice: 'target',
                ),
                throwsA(
                  isA<BridgeError>().having(
                    (e) => e.code,
                    'code',
                    'EXPORT_RETIREMENT_CLOSED',
                  ),
                ),
              );
              retirementReleaseConfirmed = true;
              return null;
            }
            if (call.method == 'chooseExportDestination') {
              destinationSelected = true;
              return {
                'selectionId': 'native-export-destination',
                'path': output.path,
              };
            }
            if (call.method == 'releaseExportDestinationSelection') {
              await expectLater(
                prepareExport(
                  handle: handle!,
                  sessionToken: 'native-export-destination',
                  requestId: 'late',
                  fileName: 'late.orange-retained.json',
                  choice: 'original',
                ),
                throwsA(
                  isA<BridgeError>().having(
                    (e) => e.code,
                    'code',
                    'EXPORT_SELECTION_CLOSED',
                  ),
                ),
              );
              if (!destinationReleased.isCompleted) {
                destinationReleased.complete();
              }
              return null;
            }
            if (call.method == 'chooseRetentionWorkspace') {
              return {
                'selectionId': 'native-retention-reader',
                'path': workspace.path,
              };
            }
            if (call.method == 'releaseRetentionSelection') {
              if (destinationSelected) {
                expect(
                  destinationReleased.isCompleted,
                  isTrue,
                  reason:
                      'destination cache/drain precedes source native release',
                );
              }
              await expectLater(
                inspectRetention(
                  handle: handle!,
                  sessionToken: 'native-retention-reader',
                ),
                throwsA(
                  isA<BridgeError>().having(
                    (e) => e.code,
                    'code',
                    'RETENTION_SELECTION_CLOSED',
                  ),
                ),
              );
              if (!released.isCompleted) released.complete();
              return null;
            }
            throw PlatformException(code: 'UNEXPECTED_OWNED_PLATFORM_CALL');
          },
        );
        final exporter = LostExportReply(handle);
        controller = RetentionController(
          NativeRetentionCommands(handle),
          exportCommands: exporter,
        );
        await controller.refresh();
        await controller.selectRun(history);
        expect(controller.operations, [operation]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RetentionPanel(controller: controller, supported: true),
              ),
            ),
          ),
        );
        await tester.tap(find.text('保留原件管理'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('选择原目录并检查保留版本'));
        await tester.tap(find.text('选择原目录并检查保留版本'));
        await helpers.settle(tester, 'export-source-inspection');
        expect(controller.error, isNull);
        expect(controller.snapshot!.original.matchesOriginalContent, isTrue);
        await tester.ensureVisible(find.text('单独选择导出目录'));
        await tester.tap(find.text('单独选择导出目录'));
        await helpers.settle(tester, 'export-destination-selection');
        expect(controller.error, isNull);
        expect(controller.exportAccess!.displayDirectory, output.path);
        expect(await output.list().length, 0);
        await tester.ensureVisible(find.text('生成导出预览'));
        await tester.tap(find.text('生成导出预览'));
        await helpers.settle(tester, 'export-actual-preview');
        expect(controller.error, isNull);
        final preview = controller.exportReview!;
        expect(preview.entries.length, 1);
        expect(preview.entries.single.matchesReviewedOriginal, isTrue);
        expect(exporter.approvals, 0);
        expect(await output.list().length, 0);
        await tester.ensureVisible(find.text('确认创建这个导出文件'));
        await tester.tap(find.text('确认创建这个导出文件'));
        await helpers.settle(tester, 'export-exact-confirmation');
        expect(controller.error, isNull);
        expect(controller.exportOutcome!.state, 'succeeded');
        expect(controller.exportOutcome!.exportId, preview.exportId);
        expect(controller.exportOutcome!.reviewDigest, preview.digest);
        expect(exporter.approvals, 1);
        expect(exporter.lookups, 1);
        final artifact = File('${output.path}/${preview.fileName}');
        final bytes = await artifact.readAsBytes();
        expect(bytes.length.toString(), preview.artifactBytes);
        final hash = await Process.run('/usr/bin/shasum', [
          '-a',
          '256',
          artifact.path,
        ]);
        expect(hash.exitCode, 0, reason: hash.stderr.toString());
        expect(
          hash.stdout.toString().split(RegExp(r'\s+')).first,
          preview.artifactSha256,
        );
        final document = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        expect(document['format'], 'orange-retained-files.v1');
        expect(document['operation_id'], operation);
        final entry =
            (document['entries'] as List).single as Map<String, dynamic>;
        expect(
          utf8.decode(base64Decode(entry['content_base64'] as String)),
          sentinel,
        );
        expect((await artifact.stat()).mode & 0x1ff, 0x180);
        expect(await source.readAsString(), '${sentinel}_EDITED');
        expect(await workspace.list().length, 2);
        await controller.prepareExport();
        expect(controller.exportReview, isNull);
        expect(controller.error, isNotNull);
        expect(await artifact.readAsBytes(), bytes);
        expect(exporter.approvals, 1);
        controller.setExportFileName('uncertain.orange-retained.json');
        await controller.prepareExport();
        expect(controller.error, isNull);
        final uncertain = controller.exportReview!;
        final fault = await Process.run('/usr/bin/sqlite3', [
          '${private.path}/host.sqlite',
          "CREATE TRIGGER export_receipt_fault BEFORE INSERT ON events WHEN NEW.kind='patch.export_completed' BEGIN SELECT RAISE(ABORT,'owned native export receipt fault');END;",
        ]);
        expect(fault.exitCode, 0, reason: fault.stderr.toString());
        await controller.approveExport();
        final removed = await Process.run('/usr/bin/sqlite3', [
          '${private.path}/host.sqlite',
          'DROP TRIGGER export_receipt_fault;',
        ]);
        expect(removed.exitCode, 0);
        expect(controller.exportOutcome!.state, 'unknown');
        expect(controller.exportNotice, isNull);
        expect(controller.error, contains('待核对'));
        expect(exporter.approvals, 2);
        expect(exporter.lookups, 2);
        final uncertainFile = File(
          '${output.path}/uncertain.orange-retained.json',
        );
        final uncertainBytes = await uncertainFile.readAsBytes();
        expect(uncertainBytes.length.toString(), uncertain.artifactBytes);
        final uncertainHash = await Process.run('/usr/bin/shasum', [
          '-a',
          '256',
          uncertainFile.path,
        ]);
        expect(uncertainHash.exitCode, 0);
        expect(
          uncertainHash.stdout.toString().split(RegExp(r'\s+')).first,
          uncertain.artifactSha256,
        );
        final uncertainDocument =
            jsonDecode(utf8.decode(uncertainBytes)) as Map<String, dynamic>;
        expect(
          utf8.decode(
            base64Decode(
              (uncertainDocument['entries'] as List).single['content_base64']
                  as String,
            ),
          ),
          sentinel,
        );
        controller.setExportFileName('pending.orange-retained.json');
        await controller.prepareExport();
        expect(controller.error, isNull);
        expect(controller.exportReview, isNotNull);
        // Both permits are now cached; stop must discard the cache before drain.
        await controller.stop().timeout(const Duration(seconds: 5));
        await destinationReleased.future.timeout(const Duration(seconds: 5));
        await released.future.timeout(const Duration(seconds: 5));
        expect(
          await File('${output.path}/pending.orange-retained.json').exists(),
          isFalse,
        );
        expect(await output.list().length, 2);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        controller = null;
        await closeHost(handle: handle);
        host = await helpers.reopenHost(private.path);
        handle = host.handle;
        final records = await listExportOutcomes(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          limit: 100,
        );
        expect(records.length, 3);
        expect(
          records.singleWhere((r) => r.exportId == preview.exportId).state,
          'succeeded',
        );
        expect(
          records.singleWhere((r) => r.exportId == uncertain.exportId).state,
          'unknown',
        );
        expect(records.where((r) => r.state == 'prepared').length, 1);
        expect(await output.list().length, 2);
        expect(await source.readAsString(), '${sentinel}_EDITED');
        expect(await workspace.list().length, 2);
        expect(
          (await listWorkspaces(
            handle: handle,
            includeRevoked: true,
          )).every((w) => !w.sessionAccess),
          isTrue,
        );
        expect(
          (await listRuns(
            handle: handle,
            limit: 10,
          )).runs.singleWhere((r) => r.runId == run.runId).phase,
          'completed',
        );
        detachedWorkspace = await workspace.rename(
          '${workspace.path}-unavailable',
        );
        expect(await workspace.exists(), isFalse);
        controller = RetentionController(NativeRetentionCommands(handle));
        await controller.refresh();
        final reopenedRun = (await listRuns(
          handle: handle,
          limit: 10,
        )).runs.singleWhere((r) => r.runId == run.runId);
        await controller.selectRun(reopenedRun);
        expect(controller.access, isNull);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RetentionPanel(controller: controller, supported: true),
              ),
            ),
          ),
        );
        await tester.tap(find.text('保留原件管理'));
        await tester.pumpAndSettle();
        final checkButton = find.byKey(
          Key('inspect-export-${uncertain.exportId}'),
        );
        await tester.ensureVisible(checkButton);
        await tester.tap(checkButton);
        await helpers.settle(tester, 'independent-export-inspection');
        expect(controller.exportInspection!.error, isNull);
        final check = controller.exportInspection!.view!;
        expect(check.recordedState, 'unknown');
        expect(check.target.matchesApprovedArtifact, isTrue);
        expect(check.target.validExportDocument, isTrue);
        expect(check.staged.kind, 'missing');
        expect(find.text('记录仍待核对。匹配结果只描述当前文件。'), findsOneWidget);
        expect(controller.access, isNull);
        expect(controller.exportAccess, isNull);
        expect(
          (await listWorkspaces(
            handle: handle,
            includeRevoked: true,
          )).every((w) => !w.sessionAccess),
          isTrue,
        );
        expect(
          (await inspectExportOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
            exportId: uncertain.exportId,
          ))!.state,
          'unknown',
        );
        await tester.ensureVisible(find.text('结束导出检查'));
        await tester.tap(find.text('结束导出检查'));
        await helpers.settle(tester, 'independent-export-inspection-release');
        await inspectionReleased.future.timeout(const Duration(seconds: 5));
        expect(controller.exportInspection!.view, isNull);
        expect(await output.list().length, 2);
        expect(await detachedWorkspace.list().length, 2);
        debugPrint(
          jsonEncode({
            'nativeExportInspection': true,
            'sourceUnavailable': true,
            'sourceAccessRestored': false,
            'unknownStillUnknown': true,
            'actualTargetMatches': true,
            'closedBeforeNativeRelease': true,
            'sourceFilesRetained': 2,
            'exportFiles': 2,
            'modelAndPicker': 'explicit fixtures',
          }),
        );
        final beforeRetirementEntryCount = await output.list().length;
        // The prior read-only evidence is complete. Exercise a separate native
        // write selection and exact confirmation with actual FRB/SQLite/files.
        await controller.exportInspection!.open(
          run.runId,
          operation,
          records.singleWhere((r) => r.exportId == uncertain.exportId),
        );
        await helpers.settle(tester, 'retirement-read');
        final retire = controller.exportInspection!.retirement!;
        expect(retire.error, isNull);
        await tester.ensureVisible(find.text('选择目录并预览移出目标'));
        await tester.tap(find.text('选择目录并预览移出目标'));
        await helpers.settle(tester, 'retirement-prepare');
        expect(retire.error, isNull);
        final retirement = retire.review!;
        expect(await uncertainFile.readAsBytes(), uncertainBytes);
        await tester.ensureVisible(find.text('确认移入保留区'));
        await tester.tap(find.text('确认移入保留区'));
        await helpers.settle(tester, 'retirement-approve');
        expect(retire.error, isNull);
        expect(retire.records.single.state, 'retained');
        expect(retirementReleaseConfirmed, isTrue);
        expect(
          controller.exportInspection!.view,
          isNull,
          reason: 'discard pre-move snapshot',
        );
        expect(await uncertainFile.exists(), isFalse);
        final retained = File(
          '${output.path}/.orange-agent-tmp-retired-${retirement.retirementId}/item',
        );
        expect(await retained.readAsBytes(), uncertainBytes);
        expect(
          await artifact.readAsBytes(),
          bytes,
          reason: 'other exported package untouched',
        );
        await tester.ensureVisible(
          find.byKey(Key('inspect-retirement-${retirement.retirementId}')),
        );
        await tester.tap(
          find.byKey(Key('inspect-retirement-${retirement.retirementId}')),
        );
        await helpers.settle(tester, 'retirement-inspect');
        expect(retire.inspection!.retained!.matchesApprovedArtifact, isTrue);
        expect(
          (await inspectExportOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
            exportId: uncertain.exportId,
          ))!.state,
          'unknown',
        );
        await tester.ensureVisible(
          find.byKey(Key('restore-retirement-${retirement.retirementId}')),
        );
        await tester.tap(
          find.byKey(Key('restore-retirement-${retirement.retirementId}')),
        );
        await helpers.settle(tester, 'restoration-open');
        final restore = retire.restoration!;
        expect(restore.error, isNull);
        final nameInput = find.byKey(
          ValueKey('restore-name-${retirement.retirementId}'),
        );
        await tester.ensureVisible(nameInput);
        await tester.enterText(
          nameInput,
          'restored-proof.orange-retained.json',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('选择目录并预览恢复副本'));
        await tester.tap(find.text('选择目录并预览恢复副本'));
        await helpers.settle(tester, 'restoration-prepare');
        expect(restore.error, isNull);
        final restoration = restore.review!;
        final restoredFile = File('${output.path}/${restoration.fileName}');
        expect(await restoredFile.exists(), isFalse);
        await tester.ensureVisible(find.text('确认创建恢复副本'));
        await tester.tap(find.text('确认创建恢复副本'));
        await helpers.settle(tester, 'restoration-approve');
        expect(restore.error, isNull);
        expect(restore.records.single.state, 'succeeded');
        expect(await restoredFile.readAsBytes(), uncertainBytes);
        expect(await retained.readAsBytes(), uncertainBytes);
        expect(restorationReleases, 1);
        // Occupied destination cannot be overwritten, including through fresh consent.
        await restore.prepare();
        expect(restore.review, isNull);
        expect(restore.error, isNotNull);
        expect(await restoredFile.readAsBytes(), uncertainBytes);
        expect(restorationReleases, 2);
        final receiptFault = await Process.run('/usr/bin/sqlite3', [
          '${private.path}/host.sqlite',
          "CREATE TRIGGER restoration_native_fault BEFORE INSERT ON events WHEN NEW.kind='patch.export_restoration_completed' BEGIN SELECT RAISE(ABORT,'owned restoration receipt failure');END;",
        ]);
        expect(
          receiptFault.exitCode,
          0,
          reason: receiptFault.stderr.toString(),
        );
        restore.setFileName('unconfirmed-copy.orange-retained.json');
        await restore.prepare();
        expect(restore.error, isNull);
        final uncertainRestoration = restore.review!;
        await restore.approve();
        expect(restore.error, isNotNull);
        expect(restore.notice, isNull);
        expect(restore.review, isNull);
        final unconfirmedFile = File(
          '${output.path}/${uncertainRestoration.fileName}',
        );
        expect(await unconfirmedFile.readAsBytes(), uncertainBytes);
        expect(restorationReleases, 3);
        final unknownRestore = restore.records.singleWhere(
          (v) => v.restorationId == uncertainRestoration.restorationId,
        );
        expect(unknownRestore.state, 'unknown');
        await restore.inspect(unknownRestore);
        expect(restore.inspection!.target.matchesApprovedArtifact, isTrue);
        expect(restore.inspection!.recordedState, 'unknown');
        await restore.approve();
        expect(restore.review, isNull);
        expect(
          (await inspectExportOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
            exportId: uncertain.exportId,
          ))!.state,
          'unknown',
        );
        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        controller = null;
        await closeHost(handle: handle);
        host = await helpers.reopenHost(private.path);
        handle = host.handle;
        final retirementRecords = await listExportRetirements(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          exportId: uncertain.exportId,
          limit: 50,
        );
        expect(retirementRecords.single.retirementId, retirement.retirementId);
        expect(retirementRecords.single.state, 'retained');
        final fresh = await authorizeExportInspection(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          exportId: uncertain.exportId,
          requestId: 'retirement-reopened-read',
          selectedDirectory: output.path,
        );
        final checked = await inspectExportRetirement(
          handle: handle,
          readSessionToken: fresh.sessionToken,
          retirementId: retirement.retirementId,
        );
        expect(checked.capsuleBound, isTrue);
        expect(checked.retained!.matchesApprovedArtifact, isTrue);
        final restoredRecords = await listExportRestorations(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          retirementId: retirement.retirementId,
          limit: 50,
        );
        expect(restoredRecords.length, 2);
        expect(
          restoredRecords
              .singleWhere((v) => v.restorationId == restoration.restorationId)
              .state,
          'succeeded',
        );
        expect(
          restoredRecords
              .singleWhere(
                (v) => v.restorationId == uncertainRestoration.restorationId,
              )
              .state,
          'unknown',
        );
        final restoredCheck = await inspectExportRestoration(
          handle: handle,
          readSessionToken: fresh.sessionToken,
          restorationId: uncertainRestoration.restorationId,
        );
        expect(restoredCheck.target.matchesApprovedArtifact, isTrue);
        expect(restoredCheck.staged.kind, 'missing');
        expect(restoredCheck.recordedState, 'unknown');
        expect(await restoredFile.readAsBytes(), uncertainBytes);
        expect(await unconfirmedFile.readAsBytes(), uncertainBytes);
        await suspendExportInspection(
          handle: handle,
          requestId: fresh.sessionToken,
        );
        expect(await uncertainFile.exists(), isFalse);
        expect(await retained.readAsBytes(), uncertainBytes);
        expect(await detachedWorkspace.list().length, 2);
        debugPrint(
          jsonEncode({
            'nativeExportRetirement': true,
            'independentWriteSelection': true,
            'exactApproval': true,
            'actualBytesRetained': true,
            'otherExportUnchanged': true,
            'unknownExportNotRepaired': true,
            'recordsSurviveReopen': true,
            'freshCapsuleInspection': true,
            'closedBeforeNativeRelease': retirementReleaseConfirmed,
            'automaticReplay': false,
            'permanentDeletion': false,
            'modelAndPicker': 'explicit fixtures',
          }),
        );
        debugPrint(
          jsonEncode({
            'nativeRetentionExport': true,
            'scope': 'export verification before retirement and restoration',
            'actualArtifactVerified': true,
            'approvalCalls': exporter.approvals,
            'lostReplyLookups': exporter.lookups,
            'receiptFailureUnknown': true,
            'pendingNeverPublished': true,
            'sourceFilesRetained': 2,
            'exportFiles': beforeRetirementEntryCount,
            'ordinaryAccessRestored': false,
            'destinationClosedBeforeSource': true,
            'recordsSurviveReopen': true,
            'modelAndPicker': 'explicit fixtures',
          }),
        );
        debugPrint(
          jsonEncode({
            'nativeExportRestoration': true,
            'independentWriteSelection': true,
            'exactApproval': true,
            'actualRestoredBytes': true,
            'capsuleRetained': true,
            'occupiedTargetUnchanged': true,
            'receiptFailureUnknown': true,
            'reopenWithoutReplay': true,
            'freshTargetInspection': true,
            'oldExportUnknownPreserved': true,
            'nativeReleaseChecks': restorationReleases,
            'restorationRecords': restoredRecords.length,
            'permanentDeletion': false,
            'modelAndPicker': 'explicit fixtures',
          }),
        );
        passed = true;
      } finally {
        if (controller != null) {
          await controller.stop();
          controller.dispose();
        }
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        if (handle != null) await closeHost(handle: handle);
        await fixture?.close();
        if (passed) {
          await output.delete(recursive: true);
          await (detachedWorkspace ?? workspace).delete(recursive: true);
          await private.delete(recursive: true);
        }
      }
    },
  );
}
