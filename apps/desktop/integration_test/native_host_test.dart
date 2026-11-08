import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/main.dart';
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  for (final scenario in [(false, false), (true, false), (false, true)]) {
    final (askFirst, createAfterRead) = scenario;
    testWidgets(
      'native UI approval questions=$askFirst creation=$createAfterRead use real private IPC and filesystem with explicit model fixture',
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
        try {
          final fixture = await LocalModelFixture.start(
            directory,
            sentinel,
            askFirst: askFirst,
            createAfterRead: createAfterRead,
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
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('选择文件夹'));
          await tester.tap(find.text('选择文件夹'));
          await tester.pumpAndSettle();
          if (createAfterRead) {
            await tester.ensureVisible(find.text('选择文件夹以允许新建'));
            await tester.tap(find.text('选择文件夹以允许新建'));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.text('连接本地模型'));
          await tester.tap(find.text('连接本地模型'));
          await tester.pumpAndSettle();
          expect(find.text('native-fixture-v1'), findsOneWidget);
          await tester.ensureVisible(
            find.byType(DropdownButtonFormField<String>),
          );
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(workspace.path).last);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'Read proof.txt');
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
          await tester.ensureVisible(find.text('开始会话'));
          await tester.tap(find.text('开始会话'));
          await tester.pumpAndSettle();
          expect(fixture.calls, 1);
          expect(fixture.failures, isEmpty);
          if (askFirst) {
            expect(find.text('Which file should I read?'), findsOneWidget);
            expect(find.text('批准这一次读取'), findsNothing);
            await tester.ensureVisible(
              find.widgetWithText(OutlinedButton, 'proof.txt'),
            );
            await tester.tap(find.widgetWithText(OutlinedButton, 'proof.txt'));
            await tester.pumpAndSettle();
            expect(
              fixture.calls,
              1,
              reason: 'Selecting a suggestion must not submit',
            );
            await tester.ensureVisible(find.text('提交回答'));
            await tester.tap(find.text('提交回答'));
            await tester.pumpAndSettle();
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
          await tester.pumpAndSettle();
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
            await tester.pumpAndSettle();
            expect(
              await File('${workspace.path}/created.txt').readAsString(),
              sentinel,
            );
          }
          expect(fixture.calls, (askFirst ? 3 : 2) + (createAfterRead ? 1 : 0));
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
          await tester.pumpAndSettle();
          expect(find.textContaining('Native fixture observed:'), findsNothing);
          expect(find.textContaining('来源文件已改变'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await released.future.timeout(const Duration(seconds: 3));
          if (createAfterRead) {
            await creationReleased.future.timeout(const Duration(seconds: 3));
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
          '6b6c08bd23a5f186508d360815dec50f30c502c9',
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
        await tester.pumpAndSettle();
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
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await tester.pumpAndSettle();
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
            await tester.pumpAndSettle();
            expect(find.text('已记住目录，需重新选择以恢复访问'), findsOneWidget);
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await tester.pumpAndSettle();
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
            await tester.pumpAndSettle();
            expect(find.text('尚未授权工作区'), findsOneWidget);
            expect(released, contains('ui-workspace-fixture-1'));
            expect(
              await listWorkspaces(handle: third.handle, includeRevoked: false),
              isEmpty,
            );
            choosePrivateRoot = true;
            await tester.ensureVisible(find.text('选择文件夹'));
            await tester.tap(find.text('选择文件夹'));
            await tester.pumpAndSettle();
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
