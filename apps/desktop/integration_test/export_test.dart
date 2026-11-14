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
                'selectionId': 'native-independent-export-check',
                'path': output.path,
              };
            }
            if (call.method == 'releaseExportInspectionSelection') {
              await expectLater(
                inspectExportFiles(
                  handle: handle!,
                  sessionToken: 'native-independent-export-check',
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
        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        controller = null;
        debugPrint(
          jsonEncode({
            'nativeRetentionExport': true,
            'actualArtifactVerified': true,
            'approvalCalls': exporter.approvals,
            'lostReplyLookups': exporter.lookups,
            'receiptFailureUnknown': true,
            'pendingNeverPublished': true,
            'sourceFilesRetained': 2,
            'exportFiles': 2,
            'ordinaryAccessRestored': false,
            'destinationClosedBeforeSource': true,
            'recordsSurviveReopen': true,
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
