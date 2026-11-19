import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/api/memory.dart' as mem;
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';
import 'memory_management_test.dart' show reopen, settle, tap;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets(
    'selected task memory requires separate write and read approvals across native FRB',
    (tester) async {
      final private = await Directory.systemTemp.createTemp('oa-task-memory-');
      final work = await Directory.systemTemp.createTemp('oa-task-work-');
      const value = 'Owned native task memory';
      final fixture = await LocalModelFixture.start(
        private,
        value,
        taskMemory: true,
      );
      String? h;
      AgentController? controller;
      try {
        final opened = await reopen(private.path);
        h = opened.handle;
        final workspace = await host.authorizeWorkspace(
          handle: h,
          requestId: 'fixture-root',
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
          requestId: 'native-parent',
          write: true,
        );
        final selection = mem.MemorySelection(
          scopeId: 'personal',
          sessionToken: access.sessionToken,
          sources: const mem.MemorySources(workspaceIds: [], memoryTokens: []),
        );
        controller = AgentController(
          NativeAgentCommands(h),
          serviceDirectory: () async => fixture.root.path,
        );
        await controller.connect();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AgentPanel(
                  controller: controller,
                  workspaces: [workspace],
                  memory: selection,
                  memoryWrite: true,
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        await tap(tester, find.byType(DropdownButtonFormField<String>));
        await tap(tester, find.text(workspace.displayPath).last);
        await tester.enterText(
          find.byType(TextField),
          'Remember my preference and read it back',
        );
        await tap(tester, find.text('允许本次任务读取记忆空间 personal'));
        await tap(tester, find.text('允许提出记忆修改，逐次确认'));
        await tap(tester, find.text('开始会话'));
        expect(controller.view!.pending.single.toolName, 'memory_write');
        await tap(tester, find.text('核对记忆修改和来源'));
        expect(find.text(value), findsOneWidget);
        expect(
          (await mem.listEntries(
            handle: h,
            selection: selection,
            limit: 10,
            includeDisabled: false,
          )).entries,
          isEmpty,
        );
        await tap(tester, find.text('确认这次记忆修改'));
        expect(controller.view!.pending.single.toolName, 'memory_read');
        expect(fixture.calls, 2);
        await tap(tester, find.text('批准这一次读取'));
        expect(controller.view!.finalText, value);
        expect(fixture.calls, 3);
        expect(fixture.failures, isEmpty);
        final id = controller.view!.runId;
        await mem.suspendAccess(handle: h, requestId: access.sessionToken);
        await expectLater(
          host.inspectRun(handle: h, runId: id),
          throwsA(isA<host.BridgeError>()),
        );
        debugPrint(
          'PASS native task memory write review, separate read approval, actual committed content and parent withdrawal',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller?.dispose();
        if (h != null) await host.closeHost(handle: h);
        await fixture.close();
        await private.delete(recursive: true);
        await work.delete(recursive: true);
      }
    },
  );
}
