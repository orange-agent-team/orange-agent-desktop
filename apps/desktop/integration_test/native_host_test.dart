import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/main.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';

Future<HostView> reopenHost(String directory) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (true) {
    try {
      return await initializeHost(applicationDataDirectory: directory);
    } on BridgeError catch (error) {
      if (error.code != 'HOST_BUSY' || DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<void> settle(WidgetTester tester, String checkpoint) async {
  debugPrint(jsonEncode({'nativeCheckpoint': checkpoint}));
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
  } catch (_) {
    final panels = tester.widgetList<AgentPanel>(find.byType(AgentPanel));
    for (final panel in panels) {
      final c = panel.controller;
      debugPrint(
        jsonEncode({
          'nativeWaitFailure': checkpoint,
          'busy': c.busy,
          'connecting': c.connecting,
          'cancelling': c.cancelling,
          'phase': c.view?.phase,
          'notice': c.notice,
          'error': c.error,
          'pending': c.view?.pending.map((p) => p.toolName).toList(),
        }),
      );
    }
    rethrow;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  for (final scenario in [
    (false, false, false),
    (true, false, false),
    (false, true, false),
    (false, false, true),
  ]) {
    final (askFirst, createAfterRead, editAfterRead) = scenario;
    testWidgets(
      'native UI approval questions=$askFirst creation=$createAfterRead editing=$editAfterRead use real private IPC and filesystem with explicit model fixture',
      (tester) async {
        final directory = await Directory.systemTemp.createTemp(
          'orange-agent-ui-',
        );
        final workspace = await Directory.systemTemp.createTemp(
          'orange-agent-work-',
        );
        final sentinel = 'NATIVE_UI_${DateTime.now().microsecondsSinceEpoch}';
        final source = await File('${workspace.path}/proof.txt')
            .writeAsString(sentinel);
        LocalModelFixture? runningFixture;
        String? handle;
        const channel = MethodChannel('orange_agent/platform');
        final released = Completer<void>();
        final creationReleased = Completer<void>();
        final editingReleased = Completer<void>();
        try {
          final fixture = await LocalModelFixture.start(
            directory,
            sentinel,
            askFirst: askFirst,
            createAfterRead: createAfterRead,
            editAfterRead: editAfterRead,
          );
          runningFixture = fixture;
          final host = await reopenHost(directory.path);
          handle = host.handle;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'chooseWorkspace') {
                  return <String, String>{
                    'selectionId': 'native-run-scope',
                    'path': workspace.path,
                  };
                }
                if (call.method == 'chooseCreationWorkspace' &&
                    createAfterRead) {
                  return <String, String>{
                    'selectionId': 'native-create-scope',
                    'path': workspace.path,
                  };
                }
                if (call.method == 'releaseCreationSelection' &&
                    createAfterRead) {
                  final workspaces = await listWorkspaces(
                    handle: host.handle,
                    includeRevoked: false,
                  );
                  final rows = await listCreationAccess(
                    handle: host.handle,
                    workspaceId: workspaces.single.workspaceId,
                  );
                  expect(rows.single.permissionActive, isTrue);
                  expect(rows.single.sessionToken, isNull);
                  if (!creationReleased.isCompleted) {
                    creationReleased.complete();
                  }
                  return null;
                }
                if (call.method == 'chooseEditingWorkspace' && editAfterRead) {
                  return <String, String>{
                    'selectionId': 'native-edit-scope',
                    'path': workspace.path,
                  };
                }
                if (call.method == 'releaseEditingSelection' && editAfterRead) {
                  final workspaces = await listWorkspaces(
                    handle: host.handle,
                    includeRevoked: false,
                  );
                  final grants = await listEditingAccess(
                    handle: host.handle,
                    workspaceId: workspaces.single.workspaceId,
                  );
                  expect(grants.single.permissionActive, isTrue);
                  expect(grants.single.sessionToken, isNull);
                  if (!editingReleased.isCompleted) editingReleased.complete();
                  return null;
                }
                if (call.method == 'releaseWorkspaceSelection') {
                  final rows = await listWorkspaces(
                    handle: host.handle,
                    includeRevoked: false,
                  );
                  expect(rows.single.permissionActive, isTrue);
                  expect(rows.single.sessionAccess, isFalse);
                  if (!released.isCompleted) released.complete();
                  return null;
                }
                throw StateError('Unexpected test platform callback');
              });
          await tester.pumpWidget(
            OrangeDesktopApp(
              connect: () async => host,
              modelServiceDirectory: () async => fixture.root.path,
            ),
          );
          await settle(tester, 'checkpoint-01');
          await tester.ensureVisible(find.text('选择文件夹'));
          await tester.tap(find.text('选择文件夹'));
          await settle(tester, 'checkpoint-02');
          if (createAfterRead) {
            await tester.ensureVisible(find.text('选择文件夹以允许新建'));
            await tester.tap(find.text('选择文件夹以允许新建'));
            await settle(tester, 'checkpoint-03');
          }
          if (editAfterRead) {
            await tester.ensureVisible(find.text('选择文件夹以允许编辑'));
            await tester.tap(find.text('选择文件夹以允许编辑'));
            await settle(tester, 'editing-scope');
          }
          await tester.ensureVisible(find.text('连接本地模型'));
          await tester.tap(find.text('连接本地模型'));
          await settle(tester, 'checkpoint-04');
          expect(find.text('native-fixture-v1'), findsOneWidget);
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
          await settle(tester, 'checkpoint-05');
          await tester.tap(find.text(workspace.path).last);
          await settle(tester, 'checkpoint-06');
          await tester.ensureVisible(
            find.descendant(
              of: find.byType(AgentPanel),
              matching: find.byType(TextField),
            ),
          );
          await tester.enterText(
            find.descendant(
              of: find.byType(AgentPanel),
              matching: find.byType(TextField),
            ),
            'Read proof.txt',
          );
          await tester.pump();
          if (askFirst) {
            await tester.ensureVisible(find.text('允许任务询问补充信息'));
            await tester.tap(find.text('允许任务询问补充信息'));
            await tester.pump();
          }
          if (createAfterRead) {
            expect(
              tester
                  .widget<CheckboxListTile>(
                    find.widgetWithText(CheckboxListTile, '允许提出新建文件请求'),
                  )
                  .value,
              isFalse,
            );
            await tester.ensureVisible(find.text('允许提出新建文件请求'));
            await tester.tap(find.text('允许提出新建文件请求'));
            await tester.pump();
          }
          if (editAfterRead) {
            final editing = find.widgetWithText(
              CheckboxListTile,
              '允许提出修改现有文件请求',
            );
            expect(tester.widget<CheckboxListTile>(editing).value, isFalse);
            await tester.ensureVisible(editing);
            await tester.tap(editing);
            await tester.pump();
          }
          await tester.ensureVisible(find.text('开始会话'));
          await tester.tap(find.text('开始会话'));
          await settle(tester, 'checkpoint-07');
          expect(fixture.calls, 1);
          expect(fixture.failures, isEmpty);
          if (askFirst) {
            expect(find.text('Which file should I read?'), findsOneWidget);
            expect(find.text('批准这一次读取'), findsNothing);
            await tester.ensureVisible(
              find.widgetWithText(OutlinedButton, 'proof.txt'),
            );
            await tester.tap(find.widgetWithText(OutlinedButton, 'proof.txt'));
            await settle(tester, 'checkpoint-08');
            expect(
              fixture.calls,
              1,
              reason: 'Selecting a suggestion must not submit',
            );
            await tester.ensureVisible(find.text('提交回答'));
            await tester.tap(find.text('提交回答'));
            await settle(tester, 'checkpoint-09');
            expect(fixture.calls, 2);
            expect(find.text('提交回答'), findsNothing);
            expect(
              find.textContaining('Native fixture observed:'),
              findsNothing,
            );
          }
          expect(find.text('批准这一次读取'), findsOneWidget);
          expect(find.textContaining('Native fixture observed:'), findsNothing);
          await tester.ensureVisible(find.text('批准这一次读取'));
          await tester.tap(find.text('批准这一次读取'));
          await settle(tester, 'checkpoint-10');
          expect(fixture.failures, isEmpty);
          if (createAfterRead) {
            expect(fixture.calls, 2);
            expect(
              await File('${workspace.path}/created.txt').exists(),
              isFalse,
            );
            expect(find.text('created.txt'), findsOneWidget);
            expect(find.text(sentinel), findsOneWidget);
            await tester.ensureVisible(find.text('批准新建这个文件'));
            await tester.tap(find.text('批准新建这个文件'));
            await settle(tester, 'checkpoint-11');
            expect(
              await File('${workspace.path}/created.txt').readAsString(),
              sentinel,
            );
          }
          if (editAfterRead) {
            expect(fixture.calls, 2);
            expect(await source.readAsString(), sentinel);
            final approval = find.widgetWithText(FilledButton, '批准这次精确修改');
            expect(tester.widget<FilledButton>(approval).onPressed, isNull);
            await tester.ensureVisible(find.text('读取实际差异'));
            await tester.tap(find.text('读取实际差异'));
            await settle(tester, 'editing-actual-preview');
            expect(find.textContaining('-$sentinel'), findsOneWidget);
            expect(tester.widget<FilledButton>(approval).onPressed, isNotNull);
            await tester.ensureVisible(approval);
            await tester.tap(approval);
            await settle(tester, 'editing-approved-effect');
            if (await source.readAsString() != '${sentinel}_EDITED') {
              final c = tester
                  .widget<AgentPanel>(find.byType(AgentPanel))
                  .controller;
              debugPrint(
                jsonEncode({
                  'nativeEditFailure': true,
                  'phase': c.view?.phase,
                  'error': c.error,
                  'notice': c.notice,
                  'pending': c.view?.pending.map((p) => p.toolName).toList(),
                  'entries': await workspace
                      .list()
                      .map(
                        (e) =>
                            e.uri.pathSegments.where((s) => s.isNotEmpty).last,
                      )
                      .toList(),
                }),
              );
              // Preserve only this test's owned data; no model credentials.
              final snapshot = await Directory.systemTemp.createTemp(
                'orange-edit-failure-',
              );
              for (final entry in await directory.list().toList()) {
                if (entry is File && entry.path.contains('host.sqlite')) {
                  await entry.copy(
                    '${snapshot.path}/${entry.uri.pathSegments.last}',
                  );
                }
              }
              final files = await Directory('${snapshot.path}/workspace')
                  .create();
              for (final entry in await workspace.list().toList()) {
                if (entry is File) {
                  await entry.copy(
                    '${files.path}/${entry.uri.pathSegments.last}',
                  );
                }
              }
              debugPrint(
                jsonEncode({
                  'ownedNativeEditSnapshot': snapshot.path,
                  'snapshotConsistency': 'diagnostic copy while Host may be open; not a certified backup',
                }),
              );
            }
            expect(await source.readAsString(), '${sentinel}_EDITED');
          }
          expect(
            fixture.calls,
            (askFirst ? 3 : 2) + ((createAfterRead || editAfterRead) ? 1 : 0),
          );
          expect(
            find.text('Native fixture observed: $sentinel'),
            findsOneWidget,
          );
          if (createAfterRead) {
            await File('${workspace.path}/created.txt').delete();
          } else {
            await source.delete();
          }
          await tester.ensureVisible(find.text('核对状态'));
          await tester.tap(find.text('核对状态'));
          await settle(tester, 'checkpoint-12');
          expect(find.textContaining('Native fixture observed:'), findsNothing);
          expect(find.textContaining('来源文件已改变'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await released.future.timeout(const Duration(seconds: 3));
          if (createAfterRead) {
            await creationReleased.future.timeout(const Duration(seconds: 3));
          }
          if (editAfterRead) {
            await editingReleased.future.timeout(const Duration(seconds: 3));
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          if (handle != null) await closeHost(handle: handle);
          await runningFixture?.close();
          await workspace.delete(recursive: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }
  testWidgets(
    'protected Unicode alias is refused through actual native IPC and FRB',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'orange-native-alias-host-',
      );
      final workspace = await Directory.systemTemp.createTemp(
        'orange-native-alias-work-',
      );
      LocalModelFixture? fixture;
      String? handle;
      try {
        await Directory('${workspace.path}/.kube').create();
        final source = await File('${workspace.path}/.kube/proof.txt')
            .writeAsString('OWNED_ALIAS_FIXTURE');
        fixture = await LocalModelFixture.start(
          directory,
          'OWNED_ALIAS_FIXTURE',
          readPath: '.Kube/proof.txt',
        );
        final host = await reopenHost(directory.path);
        handle = host.handle;
        final grant = await authorizeWorkspace(
          handle: handle,
          requestId: 'alias-test-consent',
          selectedDirectory: workspace.path,
        );
        await connectLocalModel(
          handle: handle,
          selectedDirectory: fixture.root.path,
        );
        final run = await startRun(
          handle: handle,
          workspaceId: grant.workspaceId,
          requestId: 'native-protected-alias',
          prompt: 'Reject protected aliases',
        );
        BridgeError? rejected;
        try {
          await advanceRun(
            handle: handle,
            runId: run.runId,
            expectedRevision: run.revision,
          );
        } on BridgeError catch (error) {
          rejected = error;
        }
        expect(
          fixture.failures,
          isEmpty,
          reason: 'The explicit SSE fixture must encode Unicode as UTF-8',
        );
        expect(
          rejected,
          isA<BridgeError>().having(
            (e) => e.code,
            'code',
            'RUN_SOURCE_UNAVAILABLE',
          ),
        );
        final view = await inspectRun(handle: handle, runId: run.runId);
        expect(view.phase, 'recovery_required');
        expect(view.pending, isEmpty);
        expect(view.finalText, isNull);
        expect(fixture.calls, 1);
        expect(fixture.failures, isEmpty);
        expect(await source.readAsString(), 'OWNED_ALIAS_FIXTURE');
        await suspendWorkspaceAccess(
          handle: handle,
          workspaceId: grant.workspaceId,
          sessionToken: grant.sessionToken!,
        );
        expect(
          await listUnresolvedEdits(
            handle: handle,
            runId: run.runId,
            limit: 10,
          ),
          isEmpty,
          reason: 'A read failure is not an unresolved patch publication',
        );
        await expectLater(
          inspectRun(handle: handle, runId: run.runId),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'WORKSPACE_SESSION_ACCESS_REQUIRED',
            ),
          ),
          reason: 'Metadata discovery must not restore released file access',
        );
      } finally {
        if (handle != null) await closeHost(handle: handle);
        await fixture?.close();
        await workspace.delete(recursive: true);
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'real native Host, integer transport and stale handle rejection',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'orange-native-host-',
      );
      String? openHandle;
      try {
        final platformData = await applicationDataDirectory();
        expect(platformData, isNotEmpty);
        debugPrint(
          jsonEncode({
            'sandboxPathProbe': true,
            'supportSocketBytes': utf8
                .encode('$platformData/m/engine.sock')
                .length,
            'temporarySocketBytes': utf8
                .encode('${Directory.systemTemp.path}/o/engine.sock')
                .length,
            'unixSocketLimit': 100,
          }),
        );
        final host = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        openHandle = host.handle;
        expect(
          host.runtimeSourceCommit,
          '006ff38a3624cdd96e6d576afc3a4f5ca78b81ce',
        );
        expect(host.contractVersion, 'desktop-host.v1');
        expect(
          host.availableReadTools,
          unorderedEquals([
            'read_file',
            'list_directory',
            'search_files',
            'search_text',
          ]),
        );
        final duplicate = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        expect(duplicate.handle, host.handle);
        expect(
          await validateAmount(handle: host.handle, value: '9007199254740993'),
          '9007199254740993',
        );
        expect(
          await validateAmount(
            handle: host.handle,
            value: '9223372036854775807',
          ),
          '9223372036854775807',
        );
        for (final value in ['01', '-1', '1.5', '9223372036854775808']) {
          await expectLater(
            validateAmount(handle: host.handle, value: value),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'INVALID_AMOUNT',
              ),
            ),
          );
        }
        await expectLater(
          initializeHost(applicationDataDirectory: 'relative-directory'),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'INVALID_DATA_DIRECTORY',
            ),
          ),
        );
        await tester.pumpWidget(
          OrangeDesktopApp(
            connect: () async => inspectHost(handle: host.handle),
          ),
        );
        await settle(tester, 'checkpoint-13');
        expect(find.text('本地记录已连接'), findsOneWidget);
        await closeHost(handle: host.handle);
        openHandle = null;
        await expectLater(
          inspectHost(handle: host.handle),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'STALE_HOST_HANDLE',
            ),
          ),
        );
        final reopened = await reopenHost(directory.path);
        openHandle = reopened.handle;
        expect(reopened.handle, isNot(host.handle));
        await expectLater(
          closeHost(handle: host.handle),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'STALE_HOST_HANDLE',
            ),
          ),
        );
        expect(
          (await inspectHost(handle: reopened.handle)).handle,
          reopened.handle,
        );
        final workspace = await Directory.systemTemp.createTemp(
          'orange-workspace-consent-',
        );
        try {
          // Explicit test-only consent to this app-owned temporary directory. This
          // proves the native boundary, not an OS picker/bookmark interaction.
          final grant = await authorizeWorkspace(
            handle: reopened.handle,
            requestId: 'test-consent',
            selectedDirectory: workspace.path,
          );
          expect(grant.permissionActive, isTrue);
          expect(grant.sessionAccess, isTrue);
          await expectLater(
            startRun(
              handle: reopened.handle,
              workspaceId: grant.workspaceId,
              requestId: 'native-run-no-model',
              prompt: 'Read proof.txt',
            ),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'MODEL_NOT_CONFIGURED',
              ),
            ),
          );
          await expectLater(
            connectLocalModel(
              handle: reopened.handle,
              selectedDirectory: workspace.path,
            ),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'MODEL_SERVICE_OUTSIDE_HOST_STORAGE',
              ),
            ),
          );
          await disconnectLocalModel(handle: reopened.handle);
          expect(
            (await listWorkspaces(
              handle: reopened.handle,
              includeRevoked: false,
            )).single.workspaceId,
            grant.workspaceId,
          );
          expect(
            (await listRuns(handle: reopened.handle, limit: 100)).runs,
            isEmpty,
          );
          await closeHost(handle: reopened.handle);
          openHandle = null;
          final third = await reopenHost(directory.path);
          openHandle = third.handle;
          final saved = (await listWorkspaces(
            handle: third.handle,
            includeRevoked: false,
          )).single;
          expect(saved.permissionActive, isTrue);
          expect(saved.sessionAccess, isFalse);
          expect(
            (await restoreWorkspaceAccess(
              handle: third.handle,
              workspaceId: saved.workspaceId,
            )).sessionAccess,
            isTrue,
          );
          final revoked = await revokeWorkspace(
            handle: third.handle,
            workspaceId: saved.workspaceId,
            expectedVersion: saved.permissionVersion,
          );
          expect(revoked.permissionActive, isFalse);
          expect(revoked.sessionAccess, isFalse);
          await expectLater(
            restoreWorkspaceAccess(
              handle: third.handle,
              workspaceId: saved.workspaceId,
            ),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'WORKSPACE_REVOKED',
              ),
            ),
          );
          final released = <String>[];
          final disposedScopeReleased = Completer<void>();
          var choosePrivateRoot = false;
          var selectionCounter = 0;
          const channel = MethodChannel('orange_agent/platform');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'chooseWorkspace') {
                  selectionCounter++;
                  return <String, String>{
                    'selectionId': choosePrivateRoot
                        ? 'ui-private-fixture'
                        : 'ui-workspace-fixture-$selectionCounter',
                    'path': choosePrivateRoot ? directory.path : workspace.path,
                  };
                }
                if (call.method == 'releaseWorkspaceSelection') {
                  // The real Rust API must stop process access before the
                  // explicit test-only OS selection callback is released.
                  final rows = await listWorkspaces(
                    handle: third.handle,
                    includeRevoked: false,
                  );
                  expect(rows.every((row) => !row.sessionAccess), isTrue);
                  released.add(
                    (call.arguments as Map)['selectionId'] as String,
                  );
                  if (!disposedScopeReleased.isCompleted) {
                    disposedScopeReleased.complete();
                  }
                  return null;
                }
                throw StateError('Unexpected platform callback ${call.method}');
              });
          try {
            await tester.pumpWidget(
              OrangeDesktopApp(
                key: UniqueKey(),
                connect: () => inspectHost(handle: third.handle),
              ),
            );
            await settle(tester, 'checkpoint-14');
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await settle(tester, 'checkpoint-15');
            expect(find.text('本次只读访问已授权'), findsOneWidget);
            await tester.pumpWidget(const SizedBox.shrink());
            await disposedScopeReleased.future.timeout(
              const Duration(seconds: 3),
            );
            final suspended = (await listWorkspaces(
              handle: third.handle,
              includeRevoked: false,
            )).single;
            expect(suspended.permissionActive, isTrue);
            expect(suspended.sessionAccess, isFalse);
            expect(suspended.sessionToken, isNull);
            await tester.pumpWidget(
              OrangeDesktopApp(
                key: UniqueKey(),
                connect: () => inspectHost(handle: third.handle),
              ),
            );
            await settle(tester, 'checkpoint-16');
            expect(find.text('已记住目录，需重新选择以恢复访问'), findsOneWidget);
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await settle(tester, 'checkpoint-17');
            expect(find.text('本次只读访问已授权'), findsOneWidget);
            expect(
              (await listWorkspaces(
                handle: third.handle,
                includeRevoked: false,
              )).length,
              1,
            );
            await tester.ensureVisible(find.text('撤销访问'));
            await tester.tap(find.text('撤销访问'));
            await settle(tester, 'checkpoint-18');
            expect(find.text('尚未授权工作区'), findsOneWidget);
            expect(released, contains('ui-workspace-fixture-1'));
            expect(
              await listWorkspaces(handle: third.handle, includeRevoked: false),
              isEmpty,
            );
            choosePrivateRoot = true;
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await settle(tester, 'checkpoint-19');
            expect(find.textContaining('受保护的应用数据'), findsOneWidget);
            expect(released, contains('ui-private-fixture'));
            expect(
              await listWorkspaces(handle: third.handle, includeRevoked: false),
              isEmpty,
            );
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }
        } finally {
          await workspace.delete(recursive: true);
        }
      } finally {
        if (openHandle != null) await closeHost(handle: openHandle);
        await directory.delete(recursive: true);
      }
    },
  );
}
