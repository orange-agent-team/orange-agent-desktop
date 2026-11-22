import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';
import 'native_host_test.dart' show reopenHost;
import 'managed_model_test.dart' show until;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets(
    'actual desktop reads durable model dispatch observation without replay',
    (tester) async {
      final data = await Directory.systemTemp.createTemp('oobs');
      final workspace = await Directory.systemTemp.createTemp('oow');
      LocalModelFixture? fixture;
      String? handle;
      AgentController? controller;
      try {
        final server = await LocalModelFixture.start(
          data,
          'unused',
          rejectGeneration: true,
        );
        fixture = server;
        final h = (await reopenHost(data.path)).handle;
        handle = h;
        final w = await authorizeWorkspace(
          handle: h,
          requestId: 'observation-workspace',
          selectedDirectory: workspace.path,
        );
        await connectLocalModel(handle: h, selectedDirectory: server.root.path);
        final started = await startRun(
          handle: h,
          workspaceId: w.workspaceId,
          requestId: 'observation-run',
          prompt: 'A private local fault fixture',
        );
        final failed = await advanceRun(
          handle: h,
          runId: started.runId,
          expectedRevision: started.revision,
        );
        expect(failed.phase, 'recovery_required');
        expect(failed.failure, 'model_unknown');
        final agent = AgentController(
          NativeAgentCommands(h),
          serviceDirectory: () async => server.root.path,
        );
        controller = agent;
        await agent.load(started.runId, expectedWorkspace: w.workspaceId);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AgentPanel(controller: agent, workspaces: [w]),
              ),
            ),
          ),
        );
        final button = find.text('核对模型派发记录');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await until(tester, () => agent.observedFailure != null);
        final observation = agent.observedFailure!;
        expect(observation.reason, 'gateway_failed');
        expect(observation.adapterCode, 'unavailable');
        expect(observation.waitLimitMs, '120000');
        expect(int.parse(observation.elapsedMs!), greaterThanOrEqualTo(0));
        expect(find.text('调用编号 ${observation.invocationId}'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        agent.dispose();
        controller = null;
        await closeHost(handle: h);
        handle = null;
        final reopened = (await reopenHost(data.path)).handle;
        handle = reopened;
        final restored = await inspectModelObservation(
          handle: reopened,
          runId: started.runId,
        );
        expect(restored!.invocationId, observation.invocationId);
        expect(restored.reason, 'gateway_failed');
        expect(server.calls, 1);
        debugPrint(
          jsonEncode({
            'nativeObservation': 'gateway_failed',
            'adapterCode': observation.adapterCode,
            'reopenKeptInvocation': true,
            'endpointCalls': server.calls,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller?.dispose();
        if (handle != null) await closeHost(handle: handle);
        await fixture?.close();
        await data.delete(recursive: true);
        await workspace.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
