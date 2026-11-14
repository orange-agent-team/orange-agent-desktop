import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/recovery_controller.dart';
import 'package:orange_desktop/recovery_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';
import 'native_host_test.dart' as helpers;

// Test-only response loss after an actual native commit; the retry path must
// perform only metadata lookup. All other commands call the real Host.
class LostReplyNativeCommands extends NativeRecoveryCommands {
  LostReplyNativeCommands(super.handle, this.loseReply);
  bool loseReply;
  int approvals = 0, lookups = 0;
  @override
  Future<RecoveryOutcomeView> approve(RecoveryDecisionView decision) async {
    approvals++;
    final result = await super.approve(decision);
    if (loseReply) {
      loseReply = false;
      throw StateError('owned native lost reply after commit');
    }
    return result;
  }

  @override
  Future<RecoveryOutcomeView> outcome(String run, String operation) {
    lookups++;
    return super.outcome(run, operation);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  for (final choice in [
    'keep_current_target',
    'restore_original_to_missing_target',
    'publish_staged_to_missing_target',
  ]) {
    testWidgets(
      'native exact recovery decision $choice preserves unknown history and requires separate approval',
      (tester) async {
        final private = await Directory.systemTemp.createTemp(
          'orange-recovery-host-',
        );
        final workspace = await Directory.systemTemp.createTemp(
          'orange-recovery-work-',
        );
        final sentinel =
            'RECOVERY_OWNED_${DateTime.now().microsecondsSinceEpoch}';
        final source = await File('${workspace.path}/proof.txt')
            .writeAsString(sentinel);
        LocalModelFixture? fixture;
        RecoveryController? controller;
        String? handle;
        var passed = false;
        const channel = MethodChannel('orange_agent/platform');
        final released = Completer<void>();
        final writeReleased = Completer<void>();
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
            requestId: 'native-recovery-read-base',
            selectedDirectory: workspace.path,
          );
          final edit = await authorizeEditingAccess(
            handle: handle,
            workspaceId: read.workspaceId,
            requestId: 'native-recovery-edit-base',
            selectedDirectory: workspace.path,
          );
          await connectLocalModel(
            handle: handle,
            selectedDirectory: fixture.root.path,
          );
          var run = await startEditingRun(
            handle: handle,
            workspaceId: read.workspaceId,
            requestId: 'native-recovery-run',
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
          expect(
            jsonDecode(run.pending.single.argumentsJson)['path'],
            'proof.txt',
          );
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
          final preview = await previewEditingTool(
            handle: handle,
            runId: run.runId,
            operationId: operation,
          );
          expect(preview.path, 'proof.txt');
          expect(preview.diff, contains('-$sentinel'));
          expect(preview.diff, contains('+${sentinel}_EDITED'));
          run = await approveEditingTool(
            handle: handle,
            runId: run.runId,
            operationId: operation,
            previewDigest: preview.previewDigest,
          );

          // Owned integration fixture only. No fault-injection method is added to
          // the production Host API. The OS utility is invoked without a shell.
          final sqliteVersion = await Process.run('/usr/bin/sqlite3', [
            '--version',
          ]);
          expect(sqliteVersion.exitCode, 0);
          final database = '${private.path}/host.sqlite';
          final injection = await Process.run('/usr/bin/sqlite3', [
            database,
            choice == 'keep_current_target'
                ? "CREATE TRIGGER native_recovery_receipt_fault BEFORE INSERT ON patch_version_edges BEGIN SELECT RAISE(ABORT,'owned native receipt fixture'); END;"
                : "CREATE TRIGGER native_recovery_receipt_fault BEFORE INSERT ON editing_publication_steps WHEN NEW.step=4 BEGIN SELECT RAISE(ABORT,'owned native capture fixture'); END;",
          ]);
          expect(
            injection.exitCode,
            0,
            reason:
                'Owned receipt fault must actually be installed: ${injection.stderr}',
          );
          try {
            run = await step();
          } on BridgeError {
            /* Actual state is asserted below, never assumed from an exception. */
          }
          final removal = await Process.run('/usr/bin/sqlite3', [
            database,
            'DROP TRIGGER native_recovery_receipt_fault;',
          ]);
          expect(removal.exitCode, 0);
          if (choice == 'keep_current_target') {
            expect(await source.readAsString(), '${sentinel}_EDITED');
          } else {
            expect(await source.exists(), isFalse);
          }
          expect(
            await listUnresolvedEdits(
              handle: handle,
              runId: run.runId,
              limit: 10,
            ),
            [operation],
          );
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
          final records = await listRuns(
            handle: handle,
            workspaceId: read.workspaceId,
            limit: 10,
          );
          final history = records.runs.singleWhere((r) => r.runId == run.runId);
          expect(history.phase, 'recovery_required');

          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              if (call.method == 'chooseRecoveryInspectionWorkspace') {
                return {
                  'selectionId': 'native-recovery-inspection',
                  'path': workspace.path,
                };
              }
              if (call.method == 'chooseRecoveryWriteWorkspace') {
                return {
                  'selectionId': 'native-recovery-write',
                  'path': workspace.path,
                };
              }
              if (call.method == 'releaseRecoveryWriteSelection') {
                await expectLater(
                  prepareRecoveryDecision(
                    handle: handle!,
                    readSessionToken: 'native-recovery-inspection',
                    writeSessionToken: 'native-recovery-write',
                    requestId: 'after-native-release',
                    choice: 'keep_current_target',
                  ),
                  throwsA(
                    isA<BridgeError>().having(
                      (e) => e.code,
                      'code',
                      'RECOVERY_SELECTION_CLOSED',
                    ),
                  ),
                );
                if (!writeReleased.isCompleted) writeReleased.complete();
                return null;
              }
              if (call.method == 'releaseRecoveryInspectionSelection') {
                await expectLater(
                  inspectRecovery(
                    handle: handle!,
                    sessionToken: 'native-recovery-inspection',
                  ),
                  throwsA(
                    isA<BridgeError>().having(
                      (e) => e.code,
                      'code',
                      'RECOVERY_SELECTION_CLOSED',
                    ),
                  ),
                );
                if (!released.isCompleted) released.complete();
                return null;
              }
              throw PlatformException(code: 'UNEXPECTED_TEST_PLATFORM_CALL');
            },
          );
          final commands = LostReplyNativeCommands(
            handle,
            choice == 'restore_original_to_missing_target',
          );
          controller = RecoveryController(commands);
          await controller.selectRun(history);
          expect(controller.operations, [operation]);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: RecoveryPanel(controller: controller, supported: true),
                ),
              ),
            ),
          );
          await tester.ensureVisible(find.text('选择目录进行恢复检查'));
          await tester.tap(find.text('选择目录进行恢复检查'));
          await helpers.settle(tester, 'actual-recovery-inspection');
          expect(controller.error, isNull);
          expect(controller.snapshot?.operationId, operation);
          if (choice == 'keep_current_target') {
            expect(controller.snapshot?.target.matchesResultContent, isTrue);
          } else {
            expect(controller.snapshot?.target.kind, 'missing');
          }
          expect(controller.snapshot?.original.matchesOriginalContent, isTrue);
          expect(find.text('原修改记录仍待核对'), findsOneWidget);
          expect(find.text('恢复完成'), findsNothing);
          expect(
            (await listWorkspaces(
              handle: handle,
              includeRevoked: true,
            )).every((w) => !w.sessionAccess),
            isTrue,
          );
          await expectLater(
            restoreWorkspaceAccess(
              handle: handle,
              workspaceId: read.workspaceId,
            ),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'WORKSPACE_RECOVERY_REQUIRED',
              ),
            ),
          );
          expect(find.text('批准这个处理决定'), findsNothing);
          await tester.ensureVisible(find.text('单独授权处理这次改动'));
          await tester.tap(find.text('单独授权处理这次改动'));
          await helpers.settle(tester, 'native-separate-recovery-write');
          expect(controller.writeAccess, isNotNull);
          expect(find.text('批准这个处理决定'), findsNothing);
          final label = switch (choice) {
            'keep_current_target' => '核对保留当前文件',
            'restore_original_to_missing_target' => '核对放回原件',
            _ => '核对发布待写入版本',
          };
          await tester.ensureVisible(find.text(label));
          await tester.tap(find.text(label));
          await helpers.settle(tester, 'native-actual-recovery-decision');
          expect(controller.decision?.choice, choice);
          final recoveryId = controller.decision!.recoveryId;
          if (choice == 'keep_current_target') {
            expect(await source.readAsString(), '${sentinel}_EDITED');
          } else {
            expect(await source.exists(), isFalse);
          }
          await tester.ensureVisible(find.text('批准这个处理决定'));
          await tester.tap(find.text('批准这个处理决定'));
          await helpers.settle(tester, 'native-recovery-approved-effect');
          expect(controller.error, isNull);
          expect(controller.outcome?.recoveryId, recoveryId);
          expect(controller.outcome?.choice, choice);
          expect(controller.outcome?.originalExecutionState, 'unknown');
          expect(commands.approvals, 1);
          expect(
            commands.lookups,
            choice == 'restore_original_to_missing_target' ? 1 : 0,
          );
          await writeReleased.future.timeout(const Duration(seconds: 5));
          final expected = choice == 'restore_original_to_missing_target'
              ? sentinel
              : '${sentinel}_EDITED';
          expect(await source.readAsString(), expected);
          expect(
            await workspace.list().length,
            2,
            reason: 'Other retained version is not deleted',
          );
          expect(
            (await listRuns(
              handle: handle,
              limit: 10,
            )).runs.singleWhere((r) => r.runId == run.runId).phase,
            isNot('completed'),
          );
          expect(
            (await listWorkspaces(
              handle: handle,
              includeRevoked: true,
            )).every((w) => !w.sessionAccess),
            isTrue,
          );
          await tester.ensureVisible(find.text('结束恢复检查'));
          await tester.tap(find.text('结束恢复检查'));
          await helpers.settle(tester, 'actual-recovery-inspection-release');
          await released.future.timeout(const Duration(seconds: 5));
          expect(controller.snapshot, isNull);
          expect(find.textContaining('文件："proof.txt"'), findsNothing);
          expect(await source.readAsString(), expected);
          expect(
            await listUnresolvedEdits(
              handle: handle,
              runId: run.runId,
              limit: 10,
            ),
            isEmpty,
          );
          expect(fixture.calls, 2);
          expect(fixture.failures, isEmpty);
          passed = true;
          debugPrint(
            jsonEncode({
              'nativeRecoveryDecision': true,
              'choice': choice,
              'approvalCalls': commands.approvals,
              'lostReplyLookups': commands.lookups,
              'actualReceiptFailure': true,
              'hostReopened': true,
              'ordinaryAccessRestored': false,
              'closedBeforeNativeRelease': true,
              'operationStillUnknown': true,
              'recoveryDecisionRecorded': true,
              'modelAndPicker': 'explicit fixtures',
              'sqliteVersion': sqliteVersion.stdout.toString().trim(),
            }),
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          controller?.dispose();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          if (handle != null) await closeHost(handle: handle);
          await fixture?.close();
          if (passed) {
            await workspace.delete(recursive: true);
            await private.delete(recursive: true);
          } else {
            debugPrint(
              jsonEncode({
                'ownedRecoveryDiagnostic': private.path,
                'ownedWorkspace': workspace.path,
              }),
            );
          }
        }
      },
    );
  }
}
