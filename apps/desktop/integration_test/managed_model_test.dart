import 'package:orange_desktop/agent_panel.dart';

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
  bool retainFixtures = false,
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
    if (confirmed && !retainFixtures) {
      for (final directory in directories) {
        await directory.delete(recursive: true);
      }
    } else if (confirmed) {
      debugPrint(
        jsonEncode({
          'managedFailureFixtures': directories.map((d) => d.path).toList(),
          'modelStopped': true,
        }),
      );
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

Future<void> until(
  WidgetTester tester,
  bool Function() condition, {
  String? handle,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 150));
  var refreshes = 0;
  var resumes = 0;
  List<Object> counts(List<RunSummary> rows) =>
      rows.map((r) => [r.runId, r.phase, r.steps, r.invocations]).toList();
  while (!condition() && DateTime.now().isBefore(deadline)) {
    if (handle != null &&
        refreshes < 3 &&
        find.text('内容已隐藏，重新查看时会再次验证访问权限。').evaluate().isNotEmpty) {
      final button = find.widgetWithText(OutlinedButton, '核对状态');
      if (button.evaluate().isNotEmpty &&
          tester.widget<OutlinedButton>(button).onPressed != null) {
        final before = (await listRuns(
          handle: handle,
          limit: 100,
        ).timeout(deadline.difference(DateTime.now()))).runs;
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 100));
        final after = (await listRuns(
          handle: handle,
          limit: 100,
        ).timeout(deadline.difference(DateTime.now()))).runs;
        expect(
          counts(after),
          counts(before),
          reason: 'authorized state refresh must not dispatch a model or tool',
        );
        refreshes++;
        debugPrint(
          jsonEncode({
            'managedVisibilityRecovery': true,
            'refreshes': refreshes,
            'noDispatchFromRefresh': true,
          }),
        );
      }
    }
    if (handle != null && refreshes > 0 && resumes < 2 && !condition()) {
      final resume = find.widgetWithText(OutlinedButton, '继续执行');
      if (resume.evaluate().isNotEmpty &&
          tester.widget<OutlinedButton>(resume).onPressed != null) {
        // Resume only through the same visible product action available to the
        // owner. No approval command is invoked, and unknown is not resumable.
        await tester.ensureVisible(resume);
        await tester.tap(resume);
        resumes++;
      }
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: 'bounded native model/UI transition');
}

Future<void> untilVisibleResult(
  WidgetTester tester,
  String handle,
  String text,
) async {
  await until(
    tester,
    () => find.textContaining(text).evaluate().isNotEmpty,
    handle: handle,
  );
  final rows = (await listRuns(handle: handle, limit: 100)).runs;
  expect(rows, isNotEmpty);
  expect(
    rows.every(
      (r) => r.phase == 'completed' && r.steps == 3 && r.invocations == 2,
    ),
    isTrue,
    reason: 'Each fixture Run must have exactly model→one approved tool→model, including visibility recovery',
  );
}

Future<void> enterEditablePrompt(WidgetTester tester, String value) async {
  await until(
    tester,
    () => !tester
        .widget<TextField>(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(TextField),
          ),
        )
        .readOnly,
  );
  await tester.ensureVisible(
    find.descendant(
      of: find.byType(AgentPanel),
      matching: find.byType(TextField),
    ),
  );
  // A readonly transition closes native text input while the test binding can
  // retain the same focusedEditable. Reopen through the real tap gesture.
  await tester.tap(
    find.descendant(
      of: find.byType(AgentPanel),
      matching: find.byType(TextField),
    ),
  );
  await tester.pump();
  expect(
    tester
        .widget<EditableText>(
          find.descendant(
            of: find.descendant(
              of: find.byType(AgentPanel),
              matching: find.byType(TextField),
            ),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode
        .hasFocus,
    isTrue,
    reason: 'typing requires focus on the actual editable field',
  );
  await tester.enterText(
    find.descendant(
      of: find.byType(AgentPanel),
      matching: find.byType(TextField),
    ),
    value,
  );
  await tester.pump();
  expect(
    tester
        .widget<TextField>(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text,
    value,
    reason: 'the exact new prompt must be visible before starting a run',
  );
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
      var uiCompleted = false;
      var stage = 'setup';
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
        Future<void> press(String label) async {
          final button = find.text(label);
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pump();
        }

        await press('核对权重缓存');
        await until(tester, () => find.text('缓存中尚无权重').evaluate().isNotEmpty);
        final emptyCache = await inspectModelCache(handle: host.handle);
        expect(emptyCache.state, 'absent');
        final cacheRoot = Directory('${data.path}/models');
        final prefix = File('${cacheRoot.path}/${emptyCache.sha256}.part');
        final localImport = File(
          '${cacheRoot.path}/${emptyCache.sha256}.import',
        );
        final unrelated = File('${cacheRoot.path}/${'a' * 64}.part');
        await prefix.writeAsBytes([1, 2, 3, 4, 5]);
        await localImport.writeAsBytes([6, 7, 8]);
        await unrelated.writeAsBytes([9]);
        await press('核对权重缓存');
        await until(
          tester,
          () => find
              .text('下载暂存 5 / ${emptyCache.expectedBytes} 字节')
              .evaluate()
              .isNotEmpty,
        );
        expect(
          find.text('导入暂存 3 / ${emptyCache.expectedBytes} 字节'),
          findsOneWidget,
        );
        await press('清除未完成的模型文件');
        await press('保留暂存');
        await tester.pumpAndSettle();
        expect(await prefix.exists(), isTrue);
        await press('清除未完成的模型文件');
        await press('确认清除');
        await until(
          tester,
          () => find.text('已核对，本机没有该模型的暂存数据。').evaluate().isNotEmpty,
        );
        expect(await prefix.exists(), isFalse);
        expect(await localImport.exists(), isFalse);
        expect(await unrelated.readAsBytes(), [9]);
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
        await press('核对权重缓存');
        await until(
          tester,
          () => find.text('检测到权重文件正在被读取').evaluate().isNotEmpty,
        );
        expect(find.text('权重摘要已核验'), findsOneWidget);
        await tester.ensureVisible(find.text('选择文件夹'));
        await tester.tap(find.text('选择文件夹'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('连接本地模型'));
        await tester.tap(find.text('连接本地模型'));
        await tester.pumpAndSettle();
        expect(find.text('orange-local-qwen-v1'), findsOneWidget);
        await tester.ensureVisible(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(DropdownButtonFormField<String>),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(DropdownButtonFormField<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(workspace.path).last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(TextField),
          ),
        );
        await enterEditablePrompt(
          tester,
          'Use read_file to read proof.txt with relative path proof.txt. After the tool result, answer with the exact file text.',
        );
        await tester.pump();
        await tester.ensureVisible(find.text('开始会话'));
        await tester.tap(find.text('开始会话'));
        await until(
          tester,
          () => find.text('批准这一次读取').evaluate().isNotEmpty,
          handle: host.handle,
        );
        expect(find.textContaining(sentinel), findsNothing);
        await tester.ensureVisible(find.text('批准这一次读取'));
        await tester.tap(find.text('批准这一次读取'));
        stage = 'await-read-result';
        await untilVisibleResult(tester, host.handle, sentinel);
        stage = 'prepare-second-search';
        final searchSentinel =
            'ORANGE_EVIDENCE_${DateTime.now().microsecondsSinceEpoch}';
        await File('${workspace.path}/proof.txt')
            .writeAsString('$searchSentinel\n');
        await tester.ensureVisible(
          find.descendant(
            of: find.byType(AgentPanel),
            matching: find.byType(TextField),
          ),
        );
        await enterEditablePrompt(
          tester,
          'Call search_text with exactly these arguments: {"path":".","query":"ORANGE_EVIDENCE_"}. Do not add optional fields. Do not call read_file. Wait for the search result. Then answer with the exact complete matching line text from its excerpt. Do not invent or shorten the content.',
        );
        await tester.pump();
        await tester.ensureVisible(find.text('开始会话'));
        stage = 'start-second-search';
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '开始会话'))
              .onPressed,
          isNotNull,
          reason: 'a completed first run must allow a new search',
        );
        await tester.tap(find.text('开始会话'));
        stage = 'await-search-approval';
        await until(
          tester,
          () =>
              find.text('批准这一次搜索').evaluate().isNotEmpty &&
              tester
                      .widget<FilledButton>(
                        find.widgetWithText(FilledButton, '批准这一次搜索'),
                      )
                      .onPressed !=
                  null,
          handle: host.handle,
        );
        expect(find.text('搜索文本'), findsOneWidget);
        expect(find.textContaining(searchSentinel), findsNothing);
        final searchRun = (await listRuns(
          handle: host.handle,
          limit: 100,
        )).runs.where((run) => run.phase == 'tools_pending').single;
        final searchPreview = await inspectRun(
          handle: host.handle,
          runId: searchRun.runId,
        );
        expect(searchPreview.pending.length, 1);
        expect(searchPreview.pending.single.toolName, 'search_text');
        final searchArguments = jsonDecode(
          searchPreview.pending.single.argumentsJson,
        ) as Map<String, dynamic>;
        expect(searchArguments['path'], '.');
        expect(searchArguments['query'], 'ORANGE_EVIDENCE_');
        expect(searchArguments['regular_expression'] == true, isFalse);
        await tester.ensureVisible(find.text('批准这一次搜索'));
        await tester.tap(find.text('批准这一次搜索'));
        stage = 'await-search-result';
        await untilVisibleResult(tester, host.handle, searchSentinel);
        expect(
          (await inspectRun(
            handle: host.handle,
            runId: searchRun.runId,
          )).finalText,
          contains(searchSentinel),
        );
        stage = 'source-deletion-refresh';
        await File('${workspace.path}/proof.txt').delete();
        await tester.ensureVisible(find.text('核对状态'));
        await tester.tap(find.text('核对状态'));
        await until(
          tester,
          () => find.textContaining('来源文件已改变').evaluate().isNotEmpty,
        );
        expect(find.textContaining(searchSentinel), findsNothing);
        await tester.ensureVisible(find.text('停止本地模型'));
        await tester.tap(find.text('停止本地模型'));
        await until(tester, () => find.text('服务已停止').evaluate().isNotEmpty);
        final stoppedCache = await inspectModelCache(handle: host.handle);
        expect(stoppedCache.state, 'verified');
        expect(stoppedCache.readLeaseObserved, isFalse);
        expect(stoppedCache.sha256, emptyCache.sha256);
        debugPrint(
          'PASS actual Flutter cache inspection, confirmed staging cleanup, unrelated bytes retained and active model lease released on stop',
        );
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
            'actualTextSearch': true,
            'exactSearchScopeApproved': true,
            'deletedSearchSourceCleared': true,
            'modelStopped': true,
            'nativeSelectorCallbacks':
                'explicit test-owned file/directory fixtures',
          }),
        );
        uiCompleted = true;
      } catch (error) {
        try {
          final runs = handle == null
              ? <RunSummary>[]
              : (await listRuns(
                  handle: handle,
                  limit: 20,
                ).timeout(const Duration(seconds: 2))).runs;
          final details = <Map<String, Object?>>[];
          for (final row in runs) {
            final detail = <String, Object?>{
              'run': row.runId,
              'phase': row.phase,
              'steps': row.steps,
              'invocations': row.invocations,
            };
            try {
              final view = await inspectRun(
                handle: handle!,
                runId: row.runId,
              ).timeout(const Duration(seconds: 2));
              detail['failure'] = view.failure;
              detail['pending'] = view.pending
                  .map(
                    (p) => {'tool': p.toolName, 'arguments': p.argumentsJson},
                  )
                  .toList();
            } on BridgeError catch (failure) {
              detail['viewError'] = failure.code;
            }
            details.add(detail);
          }
          final labels = tester
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data)
              .whereType<String>()
              .where(
                (text) => RegExp('操作|来源|授权|隐藏|停止|已完成|需要|未知|没有').hasMatch(text),
              )
              .take(30)
              .toList();
          final service = handle == null
              ? null
              : await inspectModelService(handle: handle)
                    .timeout(const Duration(seconds: 2));
          final evidenceFile = File('${data.path}/m/failure.json');
          final failureEvidence = await evidenceFile.exists()
              ? jsonDecode(await evidenceFile.readAsString())
              : null;
          debugPrint(
            jsonEncode({
              'modelService': service == null
                  ? null
                  : {'phase': service.phase, 'failure': service.failure},
              'modelFailureEvidence': failureEvidence,
              'managedUiFailureStage': stage,
              'exceptionType': error.runtimeType.toString(),
              'runs': details,
              'statusLabels': labels,
            }),
          );
        } catch (diagnosticError) {
          debugPrint(
            'Managed UI diagnostics unavailable at $stage: ${diagnosticError.runtimeType}',
          );
        }
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
        await confirmedCleanup(handle, [
          data,
          ipc,
          workspace,
        ], retainFixtures: !uiCompleted);
      }
    },
  );
}
