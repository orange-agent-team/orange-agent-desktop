import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'managed_model_test.dart'
    show confirmedCleanup, reopen, until, enterEditablePrompt;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets('actual desktop summaries and checked local file citations', (
    tester,
  ) async {
    final env = (await const MethodChannel('orange_agent/platform')
        .invokeMapMethod<String, dynamic>('modelServiceEnvironment'))!;
    final data = await Directory.systemTemp.createTemp('osk');
    final ipc = await Directory.systemTemp.createTemp('oi');
    final work = await Directory.systemTemp.createTemp('osw');
    final file = File('${work.path}/proof.txt');
    const proof = 'ORANGE-SKILL-FILE-82741';
    await file.writeAsString('$proof\n', flush: true);
    String? handle;
    AgentController? controller;
    try {
      final h = (await reopen(data.path)).handle;
      handle = h;
      final contents = env['contentsDirectory'] as String;
      await host.configureModelService(
        handle: h,
        contentsDirectory: contents,
        ipcDirectory: ipc.path,
        osVersion: env['osVersion'] as String,
      );
      await host.importModel(
        handle: h,
        operationId: 'skill-fixture-model',
        selectedFile: '$contents/Resources/OrangeModelService/test-model.gguf',
      );
      await host.closeModelImport(
        handle: h,
        operationId: 'skill-fixture-model',
      );
      expect(
        (await host.startModelService(
          handle: h,
          requestId: 'skill-test-engine',
        )).phase,
        'ready',
      );
      final workspace = await host.authorizeWorkspace(
        handle: h,
        requestId: 'skill-test-space',
        selectedDirectory: work.path,
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
              child: AgentPanel(controller: agent, workspaces: [workspace]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await until(tester, () => agent.skills.isNotEmpty, handle: h);
      Future<void> click(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 150));
      }

      Future<void> waitFor(bool Function() check) async {
        await until(tester, () => check() || agent.error != null, handle: h);
        expect(agent.error, isNull);
        expect(check(), isTrue);
      }

      Future<void> select(String name) async {
        await click(find.byKey(const ValueKey('local-skill-choice')));
        await tester.pumpAndSettle();
        await click(find.text('$name · 1.0.0').last);
        await tester.pumpAndSettle();
        await click(find.text('启用此版本'));
        await waitFor(
          () => agent.skills.any((v) => v.displayName == name && v.enabled),
        );
      }

      await click(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await click(find.text(workspace.displayPath).last);
      await tester.pumpAndSettle();
      await select('文本摘要');
      await enterEditablePrompt(
        tester,
        'The delivery will arrive Friday. It contains 37 crates of oranges.',
      );
      await click(find.widgetWithText(FilledButton, '开始会话'));
      await waitFor(() => agent.view?.phase == 'completed' && !agent.busy);
      final summary = agent.view!.finalText!.toLowerCase();
      expect(summary, contains('friday'));
      expect(summary, contains('37'));
      expect(agent.view!.sourceReferences, isNull);
      final previous = agent.skills.singleWhere(
        (v) => v.skillId == 'orange.text-summary',
      );
      await click(find.text('停用此版本'));
      await waitFor(
        () => agent.skills.any(
          (v) => v.skillId == previous.skillId && !v.enabled,
        ),
      );
      await click(find.text('启用此版本'));
      await waitFor(
        () => agent.skills.any(
          (v) =>
              v.skillId == previous.skillId &&
              v.enabled &&
              v.revision != previous.revision,
        ),
      );
      await expectLater(
        host.startLocalSkillRun(
          handle: h,
          workspaceId: workspace.workspaceId,
          requestId: 'stale-skill-start',
          prompt: 'This must not run.',
          selection: host.LocalSkillSelection(
            skillId: previous.skillId,
            version: previous.version,
            digest: previous.digest,
            activationRevision: previous.revision,
          ),
        ),
        throwsA(
          isA<host.BridgeError>().having(
            (e) => e.code,
            'code',
            'SKILL_ACTIVATION_CHANGED',
          ),
        ),
      );
      await select('授权文件问答');
      await enterEditablePrompt(
        tester,
        'Call read_file to read proof.txt. Return its exact evidence token and cite the file.',
      );
      await click(find.widgetWithText(FilledButton, '开始会话'));
      await waitFor(
        () => agent.view?.pending.isNotEmpty == true && !agent.busy,
      );
      expect(agent.view!.pending.first.toolName, 'read_file');
      final read = jsonDecode(
        agent.view!.pending.first.argumentsJson,
      ) as Map<String, dynamic>;
      expect(read['path'], 'proof.txt');
      await click(find.widgetWithText(FilledButton, '批准这一次读取'));
      await waitFor(() => agent.view?.phase == 'completed' && !agent.busy);
      expect(agent.view!.finalText, contains(proof));
      final cited = agent.view!.sourceReferences!.single;
      expect(cited.path, 'proof.txt');
      expect(cited.startByte, '0');
      expect(cited.endByte, utf8.encode('$proof\n').length.toString());
      expect(
        cited.sha256,
        '2a805e57e4d5e814c8b482ed5e39dffa3efb9880d9bc4f7d702ade3f8c6ed3a8',
      );
      expect(find.text('已核对的来源'), findsOneWidget);
      await file.writeAsString('replaced source\n', flush: true);
      await agent.load(agent.runId!);
      await tester.pump();
      expect(find.text('已核对的来源'), findsNothing);
      debugPrint(
        jsonEncode({
          'nativeSkillSummary': true,
          'verifiedFileReference': true,
          'changedSourceHidden': true,
          'staleActivationDenied': true,
        }),
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller?.dispose();
      await confirmedCleanup(handle, [data, ipc, work]);
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
