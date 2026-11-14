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

class LostArchiveReply extends NativeRetentionCommands {
  LostArchiveReply(super.handle);
  int approvals = 0, lookups = 0;
  @override
  Future<String> approve(RetentionReviewView review) async {
    approvals++;
    await super.approve(review);
    throw StateError('owned reply loss after actual archive commit');
  }

  @override
  Future<String?> outcome(String run, String op) {
    lookups++;
    return super.outcome(run, op);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets(
    'native retained originals require independent selection and exact archive confirmation',
    (tester) async {
      final private = await Directory.systemTemp.createTemp(
        'orange-retention-host-',
      );
      final workspace = await Directory.systemTemp.createTemp(
        'orange-retention-work-',
      );
      final sentinel =
          'RETENTION_OWNED_${DateTime.now().microsecondsSinceEpoch}';
      final source = await File('${workspace.path}/proof.txt')
          .writeAsString(sentinel);
      String? handle;
      LocalModelFixture? fixture;
      RetentionController? controller;
      bool passed = false;
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
        final preview = await previewEditingTool(
          handle: handle,
          runId: run.runId,
          operationId: operation,
        );
        run = await approveEditingTool(
          handle: handle,
          runId: run.runId,
          operationId: operation,
          previewDigest: preview.previewDigest,
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
            if (call.method == 'chooseRetentionWorkspace') {
              return {
                'selectionId': 'native-retention-reader',
                'path': workspace.path,
              };
            }
            if (call.method == 'releaseRetentionSelection') {
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
        final commands = LostArchiveReply(handle);
        controller = RetentionController(commands);
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
        await helpers.settle(tester, 'native-retention-inspection');
        expect(controller.error, isNull);
        expect(controller.snapshot!.original.matchesOriginalContent, isTrue);
        expect(controller.snapshot!.resourceActiveRecords, 1);
        expect(controller.snapshot!.ownerArchiveRecords, 0);
        expect(
          await inspectRetentionOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
          ),
          isNull,
        );
        expect(commands.approvals, 0);
        await tester.ensureVisible(find.text('生成归档预览'));
        await tester.tap(find.text('生成归档预览'));
        await helpers.settle(tester, 'native-retention-preview');
        expect(controller.error, isNull);
        expect(controller.review, isNotNull);
        final reviewId = controller.review!.reviewId;
        expect(
          await inspectRetentionOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
          ),
          isNull,
        );
        expect(await workspace.list().length, 2);
        await tester.ensureVisible(find.text('确认本次原地归档'));
        await tester.tap(find.text('确认本次原地归档'));
        await helpers.settle(tester, 'native-retention-confirmation');
        expect(controller.error, isNull);
        expect(controller.notice, isNotNull);
        expect(controller.snapshot!.archivedReviewId, reviewId);
        expect(controller.snapshot!.resourceActiveRecords, 0);
        expect(controller.snapshot!.ownerArchiveRecords, 1);
        expect(controller.snapshot!.changedSinceArchival, false);
        expect(commands.approvals, 1);
        expect(commands.lookups, 1);
        expect(await source.readAsString(), '${sentinel}_EDITED');
        expect(await workspace.list().length, 2);
        expect(
          (await listWorkspaces(
            handle: handle,
            includeRevoked: true,
          )).every((w) => !w.sessionAccess),
          isTrue,
        );
        await controller.stop();
        await released.future.timeout(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        controller = null;
        await closeHost(handle: handle);
        host = await helpers.reopenHost(private.path);
        handle = host.handle;
        expect(
          await inspectRetentionOutcome(
            handle: handle,
            runId: run.runId,
            operationId: operation,
          ),
          reviewId,
        );
        expect(
          (await listRuns(
            handle: handle,
            limit: 10,
          )).runs.singleWhere((r) => r.runId == run.runId).phase,
          'completed',
        );
        expect(await source.readAsString(), '${sentinel}_EDITED');
        expect(await workspace.list().length, 2);
        debugPrint(
          jsonEncode({
            'nativeRetention': true,
            'actualEditAndArchive': true,
            'archiveConfirmedAfterReopen': true,
            'approvalCalls': commands.approvals,
            'lostReplyLookups': commands.lookups,
            'ordinaryAccessRestored': false,
            'retainedFiles': 2,
            'closedBeforeNativeRelease': true,
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
          await workspace.delete(recursive: true);
          await private.delete(recursive: true);
        }
      }
    },
  );
}
