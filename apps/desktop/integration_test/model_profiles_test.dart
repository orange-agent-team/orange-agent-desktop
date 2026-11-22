import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/model_controller.dart';
import 'package:orange_desktop/model_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'managed_model_test.dart'
    show until, confirmedCleanup, reopen, enterEditablePrompt;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets(
    'selected local weight and existing-file patch survive profile checks',
    (tester) async {
      const fixture = String.fromEnvironment('ORANGE_SELECTED_7B');
      expect(fixture, isNotEmpty);
      final env = (await const MethodChannel('orange_agent/platform')
          .invokeMapMethod<String, dynamic>('modelServiceEnvironment'))!;
      final data = await Directory.systemTemp.createTemp('omp');
      final ipc = await Directory.systemTemp.createTemp('oi');
      final work = await Directory.systemTemp.createTemp('o7w');
      final file = File('${work.path}/note.txt');
      const original = 'status=before\nproof=desktop-qualification\n';
      const wanted = 'status=after\nproof=desktop-qualification\n';
      await file.writeAsString(original, flush: true);
      String? handle;
      ModelController? models;
      AgentController? controller;
      try {
        final h = (await reopen(data.path)).handle;
        handle = h;
        Future<host.ModelServiceView> configure(String handle) =>
            host.configureModelService(
              handle: handle,
              contentsDirectory: env['contentsDirectory'] as String,
              ipcDirectory: ipc.path,
              osVersion: env['osVersion'] as String,
            );
        final initial = await configure(h);
        expect(initial.profileId, 'local-small');
        expect(initial.selectionRevision, '0');
        final m = ModelController(
          h,
          beforeStop: () {
            controller?.clearModel();
          },
        );
        models = m;
        await m.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ModelPanel(controller: m)),
            ),
          ),
        );
        Future<void> click(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pump(const Duration(milliseconds: 150));
        }

        await click(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await click(find.text('Qwen2.5 7B · 审阅与补丁').last);
        await until(tester, () => m.view?.profileId == 'local-7b');
        expect(find.text('下载审核模型'), findsNothing);
        expect(m.view!.selectionRevision, '1');
        expect(m.view!.inferenceThreads, inInclusiveRange(1, 8));
        debugPrint(jsonEncode({'desktop7bThreads': m.view!.inferenceThreads}));
        for (final op in [
          () => host.startModelService(
            handle: h,
            requestId: 'stale-default-start',
          ),
          () => host.selectModelProfile(
            handle: h,
            profileId: 'local-small',
            expectedRevision: '0',
          ),
        ]) {
          await expectLater(
            op(),
            throwsA(
              isA<host.BridgeError>().having(
                (e) => e.code,
                'code',
                'MODEL_SELECTION_CHANGED',
              ),
            ),
          );
        }
        await expectLater(
          host.downloadModelForProfile(
            handle: h,
            operationId: 'no-url',
            selectionRevision: '1',
          ),
          throwsA(
            isA<host.BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_PROFILE_IMPORT_ONLY',
            ),
          ),
        );
        final imported = await host.importModelForProfile(
          handle: h,
          operationId: 'actual-selected-weight',
          selectedFile: fixture,
          selectionRevision: '1',
        );
        await host.closeModelImport(
          handle: h,
          operationId: 'actual-selected-weight',
        );
        expect(imported.installed, isTrue);
        await m.refresh();
        await m.start();
        expect(m.view!.phase, 'ready');
        final space = await host.authorizeWorkspace(
          handle: h,
          requestId: 'workspace',
          selectedDirectory: work.path,
        );
        final edit = await host.authorizeEditingAccess(
          handle: h,
          workspaceId: space.workspaceId,
          requestId: 'edit-permission',
          selectedDirectory: work.path,
        );
        final agent = AgentController(
          ManagedAgentCommands(h, m),
          serviceDirectory: () async => 'managed',
        );
        controller = agent;
        await agent.connect();
        expect(agent.model!.qualifiedSkills, isTrue);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AgentPanel(
                  controller: agent,
                  workspaces: [space],
                  editings: [edit],
                ),
              ),
            ),
          ),
        );
        await until(
          tester,
          () => agent.skills.any((s) => s.skillId == 'orange.reviewed-patch'),
        );
        await click(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await click(find.text(space.displayPath).last);
        await tester.pumpAndSettle();
        await click(find.byKey(const ValueKey('local-skill-choice')));
        await tester.pumpAndSettle();
        await click(find.text('批准后应用补丁 · 1.0.0').last);
        await tester.pumpAndSettle();
        await click(find.text('启用此版本'));
        await until(
          tester,
          () => agent.skills.any(
            (s) => s.skillId == 'orange.reviewed-patch' && s.enabled,
          ),
        );
        await enterEditablePrompt(
          tester,
          'First call read_file with only {"path":"note.txt"}. Then call apply_patch once with ${jsonEncode({'path': 'note.txt', 'expected_sha256': 'SHA_FROM_READ', 'patch': '@@ -1 +1 @@\n-status=before\n+status=after\n'})}. Replace SHA_FROM_READ with the actual read digest. Keep the second line intact. After the approved edit is committed, reply with status=after.',
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '开始会话'))
              .onPressed,
          isNull,
        );
        await click(find.text('允许提出修改现有文件请求'));
        await click(find.widgetWithText(FilledButton, '开始会话'));
        Future<void> waitingForToolOrEnd() async {
          await until(
            tester,
            () =>
                agent.error != null ||
                (!agent.busy &&
                    ((agent.view?.pending.isNotEmpty ?? false) ||
                        [
                          'completed',
                          'failed',
                          'recovery_required',
                        ].contains(agent.view?.phase))),
            handle: h,
          );
          debugPrint(
            jsonEncode({
              'qualifiedPatchPhase': agent.view?.phase,
              'failure': agent.view?.failure,
              'pending': agent.view?.pending.map((p) => p.toolName).toList(),
              'invocations': agent.view?.invocations,
            }),
          );
          if (agent.view?.phase == 'recovery_required') {
            await click(find.text('核对模型派发记录'));
            await until(
              tester,
              () =>
                  agent.observedFailure != null ||
                  agent.observationMessage != null,
            );
            final obs = agent.observedFailure;
            debugPrint(
              jsonEncode({
                'nativeDispatchObservation': obs?.reason,
                'waitLimitMs': obs?.waitLimitMs,
                'elapsedMs': obs?.elapsedMs,
              }),
            );
          }
          expect(agent.error, isNull);
          expect(
            agent.view?.phase,
            isNot(anyOf('failed', 'recovery_required')),
            reason: agent.view?.failure,
          );
        }

        await waitingForToolOrEnd();
        expect(agent.view!.pending.first.toolName, 'read_file');
        await click(find.text('批准这一次读取'));
        await waitingForToolOrEnd();
        expect(agent.view!.pending.first.toolName, 'apply_patch');
        expect(await file.readAsString(), original);
        await click(find.text('读取实际差异'));
        await until(tester, () => agent.editPreviewMatches);
        expect(agent.editPreview!.diff, contains('+status=after'));
        expect(await file.readAsString(), original);
        await click(find.text('批准这次精确修改'));
        await waitingForToolOrEnd();
        if (agent.view!.pending.isNotEmpty) {
          expect(agent.view!.pending.first.toolName, 'read_file');
          await click(find.text('批准这一次读取'));
          await waitingForToolOrEnd();
        }
        expect(agent.view!.phase, 'completed');
        expect(await file.readAsString(), wanted);
        await m.stop();
        expect(m.view!.phase, 'stopped');
        await tester.pumpWidget(const SizedBox());
        agent.dispose();
        controller = null;
        m.dispose();
        models = null;
        await host.closeHost(handle: h);
        handle = null;
        final reopened = (await reopen(data.path)).handle;
        handle = reopened;
        final restored = await configure(reopened);
        expect(restored.profileId, 'local-7b');
        expect(restored.selectionRevision, '1');
        expect(restored.installed, isTrue);
        final small = await host.selectModelProfile(
          handle: reopened,
          profileId: 'local-small',
          expectedRevision: '1',
        );
        expect(small.profileId, 'local-small');
        expect(small.selectionRevision, '2');
        await expectLater(
          host.startModelServiceForProfile(
            handle: reopened,
            requestId: 'stale-7b',
            selectionRevision: '1',
          ),
          throwsA(
            isA<host.BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_SELECTION_CHANGED',
            ),
          ),
        );
        debugPrint(
          jsonEncode({
            'approved7bDesktopPatch': true,
            'persistedSelection': true,
            'staleProfileDenied': true,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller?.dispose();
        models?.dispose();
        await confirmedCleanup(handle, [data, ipc, work]);
      }
    },
    timeout: const Timeout(Duration(minutes: 23)),
  );
}
