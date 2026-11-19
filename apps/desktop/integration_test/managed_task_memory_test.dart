import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/api/memory.dart' as mem;
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'managed_model_test.dart'
    show confirmedCleanup, reopen, until, enterEditablePrompt;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets(
    'packaged CPU model reads and writes memory through separate native UI approvals',
    (tester) async {
      final environment = (await const MethodChannel('orange_agent/platform')
          .invokeMapMethod<String, dynamic>('modelServiceEnvironment'))!;
      final contents = environment['contentsDirectory'] as String;
      final data = await Directory.systemTemp.createTemp('mmh');
      final ipc = await Directory.systemTemp.createTemp('mm');
      final work = await Directory.systemTemp.createTemp('mmw');
      String? h;
      AgentController? controller;
      try {
        final opened = await reopen(data.path);
        h = opened.handle;
        await host.configureModelService(
          handle: h,
          contentsDirectory: contents,
          ipcDirectory: ipc.path,
          osVersion: environment['osVersion'] as String,
        );
        await host.importModel(
          handle: h,
          operationId: 'fixture-model',
          selectedFile:
              '$contents/Resources/OrangeModelService/test-model.gguf',
        );
        final service = await host.startModelService(
          handle: h,
          requestId: 'fixture-start',
        );
        expect(service.phase, 'ready');
        final workspace = await host.authorizeWorkspace(
          handle: h,
          requestId: 'fixture-work',
          selectedDirectory: work.path,
        );
        final scope = await mem.createScope(
          handle: h,
          scopeId: 'personal',
          shared: false,
        );
        final access = await mem.authorizeScope(
          handle: h,
          scopeId: scope.scopeId,
          revision: scope.revision,
          requestId: 'parent',
          write: true,
        );
        final selection = mem.MemorySelection(
          scopeId: scope.scopeId,
          sessionToken: access.sessionToken,
          sources: const mem.MemorySources(workspaceIds: [], memoryTokens: []),
        );
        String code() => List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final readCode = 'ORANGE_DESKTOP_${code()}',
            writeCode = 'ORANGE_DESKTOP_${code()}';
        final seed = await mem.prepareEdit(
          handle: h,
          selection: selection,
          edit: mem.MemoryEdit(
            requestId: 'seed',
            entryId: 'proof',
            delete: false,
            title: 'Verification code',
            content: readCode,
            enabled: true,
          ),
        );
        await mem.approveEdit(
          handle: h,
          selection: selection,
          draftId: seed.draftId,
          approvalDigest: seed.approvalDigest,
        );
        final agent = AgentController(
          NativeAgentCommands(h),
          serviceDirectory: () async => '${data.path}/m',
        );
        controller = agent;
        await agent.connect();
        expect(agent.model, isNotNull);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AgentPanel(
                  controller: agent,
                  workspaces: [workspace],
                  memory: selection,
                  memoryWrite: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> click(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pump(const Duration(milliseconds: 100));
        }

        Future<void> waitFor(bool Function() predicate) async {
          await until(
            tester,
            () => predicate() || agent.error != null,
            handle: h,
          );
          expect(agent.error, isNull);
          expect(predicate(), isTrue);
        }

        await click(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await click(find.text(workspace.displayPath).last);
        await tester.pumpAndSettle();
        await click(find.text('允许本次任务读取记忆空间 personal'));
        await enterEditablePrompt(
          tester,
          'Read the body of entry proof in the personal memory scope. Reply with the exact verification code stored in its content.',
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '开始会话'))
              .onPressed,
          isNotNull,
        );
        await click(find.text('开始会话'));
        expect(
          agent.runId,
          isNotNull,
          reason: 'start button must dispatch a real task',
        );
        await waitFor(
          () => agent.view?.pending.firstOrNull?.toolName == 'memory_read',
        );
        final readArgs = jsonDecode(agent.view!.pending.single.argumentsJson);
        expect(readArgs['entry_id'], 'proof');
        expect(readArgs['scope_id'], 'personal');
        expect(readArgs['mode'], 'entry');
        await click(find.text('批准这一次读取'));
        await waitFor(() => agent.view?.phase == 'completed');
        expect(agent.view!.finalText, contains(readCode));
        await click(find.text('允许提出记忆修改，逐次确认'));
        await enterEditablePrompt(
          tester,
          'Create a new enabled memory in my personal scope titled Verification code. Store this exact code as its content: $writeCode. Confirm the save after approval.',
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '开始会话'))
              .onPressed,
          isNotNull,
        );
        await click(find.text('开始会话'));
        expect(
          agent.runId,
          isNotNull,
          reason: 'start button must dispatch a real task',
        );
        await waitFor(
          () => agent.view?.pending.firstOrNull?.toolName == 'memory_write',
        );
        await click(find.text('核对记忆修改和来源'));
        await waitFor(() => agent.memoryReviewMatches);
        final draft = jsonDecode(agent.memoryReview!.reviewJson);
        expect(draft['mutation'], 'put');
        expect(draft['expected_version'], isNull);
        expect(draft['payload']['content'], writeCode);
        expect(draft['payload']['title'], 'Verification code');
        expect(draft['scope_id'], 'personal');
        expect(
          (await mem.listEntries(
            handle: h,
            selection: selection,
            limit: 10,
            includeDisabled: false,
          )).entries.length,
          1,
        );
        await click(find.text('确认这次记忆修改'));
        await waitFor(() => agent.view?.phase == 'completed');
        final fact = await mem.readEntry(
          handle: h,
          selection: selection,
          entryId: draft['entry_id'] as String,
          expectedVersion: '1',
          startByte: 0,
          maxBytes: 4096,
          includeDisabled: false,
        );
        expect(fact.content, writeCode);
        expect(fact.origin, 'model_inference');
        await mem.suspendAccess(handle: h, requestId: access.sessionToken);
        await expectLater(
          host.inspectRun(handle: h, runId: agent.runId!),
          throwsA(isA<host.BridgeError>()),
        );
        debugPrint(
          jsonEncode({
            'packagedMemory': true,
            'actualModelRead': true,
            'actualModelWrite': true,
            'readApprovals': 1,
            'writeApprovals': 1,
            'sourceWithdrawn': true,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller?.dispose();
        await confirmedCleanup(h, [data, ipc, work]);
      }
    },
  );
}
