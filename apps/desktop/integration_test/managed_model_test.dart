import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';
import 'package:orange_desktop/main.dart';

Future<HostView> reopen(String root) async {
  for (var i = 0; i < 100; i++) {
    try {
      return await initializeHost(applicationDataDirectory: root);
    } on BridgeError catch (e) {
      if (e.code != 'HOST_BUSY') rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  throw StateError('Host did not release its owned journal');
}

Future<void> confirmedCleanup(
  String? handle,
  List<Directory> directories, {
  bool noHandleStopped = true,
}) async {
  var confirmed = handle == null && noHandleStopped;
  try {
    if (handle != null) {
      try {
        var state = await inspectModelService(handle: handle);
        if (state.instanceId != null &&
            !{'idle', 'stopped'}.contains(state.phase)) {
          state = await stopModelService(
            handle: handle,
            instanceId: state.instanceId!,
          );
        }
        confirmed = {'idle', 'stopped'}.contains(state.phase);
      } on BridgeError catch (error) {
        if (error.code == 'MODEL_SERVICE_NOT_CONFIGURED') {
          final record = File('${directories.first.path}/m/process.json');
          final history = File('${directories.first.path}/m/manager.json');
          final entries = await history.exists()
              ? (jsonDecode(await history.readAsString())
                        as Map<String, dynamic>)['entries']
                    as List<dynamic>
              : <dynamic>[];
          confirmed =
              entries.every((entry) => entry['phase'] == 'stopped') &&
              (!await record.exists() ||
                  (jsonDecode(await record.readAsString())
                          as Map<String, dynamic>)['phase'] ==
                      'stopped');
        } else {
          rethrow;
        }
      }
    }
  } finally {
    if (handle != null) await closeHost(handle: handle);
    if (confirmed) {
      for (final directory in directories) {
        await directory.delete(recursive: true);
      }
    } else {
      debugPrint(
        'Managed fixture retained because model cleanup was not confirmed',
      );
    }
  }
  expect(
    confirmed,
    isTrue,
    reason: 'temporary state is removed only after confirmed process cleanup',
  );
}

Future<void> until(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 150));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: 'bounded native model/UI transition');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets(
    'actual packaged model installs, survives idle heartbeat, fences instance stop and restores completed command history',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('真实受管模型验证'))),
      );
      final environment = (await const MethodChannel('orange_agent/platform')
          .invokeMapMethod<String, dynamic>('modelServiceEnvironment'))!;
      final contents = environment['contentsDirectory'] as String;
      final manifest = jsonDecode(
        await File('$contents/Resources/OrangeModelService/manifest.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(
        manifest['test_model_included'],
        isTrue,
        reason: 'explicit fixed-weight acceptance payload required; never skip real inference',
      );
      final data = await Directory.systemTemp.createTemp('om-state-');
      final ipc = await Directory.systemTemp.createTemp('om');
      final workspace = await Directory.systemTemp.createTemp('om-work-');
      final sentinel = 'MANAGED_${DateTime.now().microsecondsSinceEpoch}';
      await File('${workspace.path}/proof.txt').writeAsString(sentinel);
      String? handle;
      String? activeInstance;
      try {
        var host = await reopen(data.path);
        handle = host.handle;
        Future<ModelServiceView> configure() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            try {
              return await configureModelService(
                handle: host.handle,
                contentsDirectory: contents,
                ipcDirectory: ipc.path,
                osVersion: environment['osVersion'] as String,
              );
            } on BridgeError catch (error) {
              if (error.code != 'MODEL_SERVICE_BUSY') rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          throw StateError('Previous model owner did not drain');
        }

        var service = await configure();
        expect(service.phase, 'idle');
        expect(service.installed, isFalse);
        service = await importModel(
          handle: host.handle,
          operationId: 'managed-import-1',
          selectedFile:
              '$contents/Resources/OrangeModelService/test-model.gguf',
        );
        await closeModelImport(
          handle: host.handle,
          operationId: 'managed-import-1',
        );
        expect(service.installed, isTrue);
        service = await startModelService(
          handle: host.handle,
          requestId: 'managed-start-1',
        );
        activeInstance = service.instanceId;
        expect(service.phase, 'ready');
        expect(activeInstance, isNotNull);
        debugPrint(
          'Managed model ready; checking35 seconds with no Journal commands',
        );
        await Future<void>.delayed(const Duration(seconds: 35));
        expect((await inspectModelService(handle: host.handle)).phase, 'ready');
        expect(
          (await startModelService(
            handle: host.handle,
            requestId: 'managed-start-1',
          )).instanceId,
          activeInstance,
        );
        await expectLater(
          stopModelService(handle: host.handle, instanceId: 'wrong-instance'),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_INSTANCE_CHANGED',
            ),
          ),
        );
        final grant = await authorizeWorkspace(
          handle: host.handle,
          requestId: 'managed-workspace',
          selectedDirectory: workspace.path,
        );
        var run = await startRun(
          handle: host.handle,
          workspaceId: grant.workspaceId,
          requestId: 'managed-run',
          prompt: 'Use read_file to read proof.txt with the relative path proof.txt. Do not guess its content. After the tool result is returned answer with the exact file text.',
        );
        var approvals = 0;
        for (var step = 0; step < 16 && run.phase != 'completed'; step++) {
          expect(['ready', 'tools_pending'], contains(run.phase));
          if (run.pending.isNotEmpty) {
            await expectLater(
              advanceRun(
                handle: host.handle,
                runId: run.runId,
                expectedRevision: run.revision,
              ),
              throwsA(
                isA<BridgeError>().having(
                  (e) => e.code,
                  'code',
                  'TOOL_APPROVAL_REQUIRED',
                ),
              ),
            );
            for (final tool in run.pending.toList()) {
              final args =
                  jsonDecode(tool.argumentsJson) as Map<String, dynamic>;
              expect(tool.toolName, 'read_file');
              expect(args['path'], 'proof.txt');
              run = await approveTool(
                handle: host.handle,
                runId: run.runId,
                operationId: tool.operationId,
                expectedDigest: tool.argumentDigest,
              );
              approvals++;
            }
          }
          run = await advanceRun(
            handle: host.handle,
            runId: run.runId,
            expectedRevision: run.revision,
          );
        }
        expect(run.phase, 'completed');
        expect(run.finalText, contains(sentinel));
        expect(approvals, greaterThan(0));
        expect(
          (await stopModelService(
            handle: host.handle,
            instanceId: activeInstance!,
          )).phase,
          'stopped',
        );
        final first = activeInstance;
        activeInstance = null;
        service = await startModelService(
          handle: host.handle,
          requestId: 'managed-start-2',
        );
        activeInstance = service.instanceId;
        expect(service.phase, 'ready');
        expect(activeInstance, isNot(first));
        expect(
          (await cancelModelStart(
            handle: host.handle,
            requestId: 'managed-start-1',
          )).instanceId,
          activeInstance,
        );
        expect((await inspectModelService(handle: host.handle)).phase, 'ready');
        await closeHost(handle: host.handle);
        handle = null;
        final receipt = File('${data.path}/m/process.json');
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        var stopped = false;
        while (DateTime.now().isBefore(deadline)) {
          final value =
              jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
          if (value['phase'] == 'stopped' &&
              value['instance_id'] == activeInstance) {
            stopped = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          stopped,
          isTrue,
          reason: 'Host close must request actual owned helper/model cleanup',
        );
        activeInstance = null;
        host = await reopen(data.path);
        handle = host.handle;
        service = await configure();
        expect(service.phase, 'stopped');
        expect(service.installed, isTrue);
        expect(
          (await startModelService(
            handle: host.handle,
            requestId: 'managed-start-2',
          )).phase,
          'stopped',
          reason: 'completed start request must not launch again after reopen',
        );
        await cancelModelStart(
          handle: host.handle,
          requestId: 'cancel-before-start',
        );
        await expectLater(
          startModelService(
            handle: host.handle,
            requestId: 'cancel-before-start',
          ),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_START_CANCELLED',
            ),
          ),
        );
        await closeHost(handle: host.handle);
        handle = null;
        final prior = await receipt.readAsString();
        final unowned = jsonDecode(prior) as Map<String, dynamic>;
        unowned['phase'] = 'ready';
        unowned['pid'] = pid;
        await receipt.writeAsString(jsonEncode(unowned));
        host = await reopen(data.path);
        handle = host.handle;
        service = await configure();
        expect(service.phase, 'recovery_required');
        await expectLater(
          startModelService(
            handle: host.handle,
            requestId: 'unowned-must-not-start',
          ),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_RECOVERY_REQUIRED',
            ),
          ),
        );
        await expectLater(
          stopModelService(
            handle: host.handle,
            instanceId: service.instanceId!,
          ),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_RECOVERY_REQUIRED',
            ),
          ),
        );
        await closeHost(handle: host.handle);
        handle = null;
        // Restore the exact confirmed receipt altered only by this fixture;
        // product code never synthesizes a stopped record or signals stored PID.
        await receipt.writeAsString(prior);
        host = await reopen(data.path);
        handle = host.handle;
        service = await configure();
        expect(service.phase, 'stopped');
        await expectLater(
          startModelService(
            handle: host.handle,
            requestId: 'cancel-before-start',
          ),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_START_CANCELLED',
            ),
          ),
        );
        debugPrint(
          jsonEncode({
            'managedModelAcceptance': true,
            'realWeightsImported': true,
            'idleHeartbeatSeconds': 35,
            'actualModelResultMatched': true,
            'approvals': approvals,
            'restartNoReplay': true,
            'modelStopped': true,
          }),
        );
      } finally {
        await confirmedCleanup(handle, [
          data,
          ipc,
          workspace,
        ], noHandleStopped: activeInstance == null);
      }
    },
  );
  testWidgets(
    'production model buttons import and start a real packaged model before explicit Agent tool approval',
    (tester) async {
      const platform = MethodChannel('orange_agent/platform');
      final environment = (await platform.invokeMapMethod<String, dynamic>(
        'modelServiceEnvironment',
      ))!;
      final contents = environment['contentsDirectory'] as String;
      final data = await Directory.systemTemp.createTemp('omu-state-');
      final ipc = await Directory.systemTemp.createTemp('omu');
      final workspace = await Directory.systemTemp.createTemp('omu-work-');
      final sentinel = 'MANAGED_UI_${DateTime.now().microsecondsSinceEpoch}';
      await File('${workspace.path}/proof.txt').writeAsString(sentinel);
      String? handle;
      try {
        final host = await reopen(data.path);
        handle = host.handle;
        final released = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, (call) async {
              switch (call.method) {
                case 'modelServiceEnvironment':
                  return {...environment, 'ipcDirectory': ipc.path};
                case 'chooseModelFile':
                  return {
                    'selectionId': 'managed-ui-import',
                    'path':
                        '$contents/Resources/OrangeModelService/test-model.gguf',
                  };
                case 'chooseWorkspace':
                  return {
                    'selectionId': 'managed-ui-work',
                    'path': workspace.path,
                  };
                case 'releaseModelSelection':
                  try {
                    await importModel(
                      handle: host.handle,
                      operationId: 'managed-ui-import',
                      selectedFile:
                          '$contents/Resources/OrangeModelService/test-model.gguf',
                    );
                    throw StateError('Closed import scope was reused');
                  } on BridgeError catch (error) {
                    expectSync(error.code, 'MODEL_IMPORT_CLOSED');
                  }
                  released.add('model');
                  return null;
                case 'releaseWorkspaceSelection':
                  expectSync(
                    (await listWorkspaces(
                      handle: host.handle,
                      includeRevoked: false,
                    )).every((row) => !row.sessionAccess),
                    isTrue,
                  );
                  released.add('workspace');
                  return null;
                default:
                  throw StateError('unexpected platform fixture callback');
              }
            });
        await tester.pumpWidget(OrangeDesktopApp(connect: () async => host));
        await until(tester, () => find.text('导入模型文件').evaluate().isNotEmpty);
        await tester.ensureVisible(find.text('导入模型文件'));
        await tester.tap(find.text('导入模型文件'));
        await until(
          tester,
          () => find.text('模型文件已校验并保存到本机。').evaluate().isNotEmpty,
        );
        expect(released, contains('model'));
        await tester.ensureVisible(find.text('启动本地模型'));
        await tester.tap(find.text('启动本地模型'));
        await until(tester, () => find.text('服务已就绪').evaluate().isNotEmpty);
        await tester.ensureVisible(find.text('选择文件夹'));
        await tester.tap(find.text('选择文件夹'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('连接本地模型'));
        await tester.tap(find.text('连接本地模型'));
        await tester.pumpAndSettle();
        expect(find.text('orange-local-qwen-v1'), findsOneWidget);
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>),
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(workspace.path).last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(TextField));
        await tester.enterText(
          find.byType(TextField),
          'Use read_file to read proof.txt with relative path proof.txt. After the tool result, answer with the exact file text.',
        );
        await tester.pump();
        await tester.ensureVisible(find.text('开始会话'));
        await tester.tap(find.text('开始会话'));
        await until(tester, () => find.text('批准这一次读取').evaluate().isNotEmpty);
        expect(find.textContaining(sentinel), findsNothing);
        await tester.ensureVisible(find.text('批准这一次读取'));
        await tester.tap(find.text('批准这一次读取'));
        await until(
          tester,
          () => find.textContaining(sentinel).evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.text('停止本地模型'));
        await tester.tap(find.text('停止本地模型'));
        await until(tester, () => find.text('服务已停止').evaluate().isNotEmpty);
        expect(
          (await inspectModelService(handle: host.handle)).phase,
          'stopped',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await until(tester, () => released.contains('workspace'));
        debugPrint(
          jsonEncode({
            'managedUiAcceptance': true,
            'actualWeights': true,
            'actualModel': true,
            'explicitToolApproval': true,
            'resultMatched': true,
            'modelStopped': true,
            'nativeSelectorCallbacks':
                'explicit test-owned file/directory fixtures',
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
        await confirmedCleanup(handle, [data, ipc, workspace]);
      }
    },
  );
}
