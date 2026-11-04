import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/main.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

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
        final host = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        openHandle = host.handle;
        expect(
          host.runtimeSourceCommit,
          'f5b364410c3f8f48471c67111fb6da5afdc4a144',
        );
        expect(host.contractVersion, 'desktop-host.v1');
        expect(
          host.availableReadTools,
          unorderedEquals(['read_file', 'list_directory']),
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
          var choosePrivateRoot = false;
          const channel = MethodChannel('orange_agent/platform');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'chooseWorkspace') {
                  return <String, String>{
                    'selectionId': choosePrivateRoot
                        ? 'ui-private-fixture'
                        : 'ui-workspace-fixture',
                    'path': choosePrivateRoot ? directory.path : workspace.path,
                  };
                }
                if (call.method == 'releaseWorkspaceSelection') {
                  released.add(
                    (call.arguments as Map)['selectionId'] as String,
                  );
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
            expect(released, contains('ui-workspace-fixture'));
            expect(
              await listWorkspaces(handle: third.handle, includeRevoked: false),
              isEmpty,
            );
            choosePrivateRoot = true;
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
