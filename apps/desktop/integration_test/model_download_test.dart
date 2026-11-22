import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/model_controller.dart';
import 'package:orange_desktop/model_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets(
    'desktop model download is consented, cancellable and bound to the catalog',
    (tester) async {
      const live = bool.fromEnvironment('ORANGE_TEST_LIVE_DOWNLOAD');
      final env = (await const MethodChannel('orange_agent/platform')
          .invokeMapMethod<String, dynamic>('modelServiceEnvironment'))!;
      final root = await Directory.systemTemp.createTemp('oa-model-cache-');
      final ipc = await Directory.systemTemp.createTemp('om');
      final host = await initializeHost(applicationDataDirectory: root.path);
      final controller = ModelController(host.handle, beforeStop: () {});
      try {
        final contents = env['contentsDirectory'] as String;
        final embedded = File(
          '$contents/Resources/OrangeModelService/test-model.gguf',
        );
        expect(
          await embedded.exists(),
          !live,
          reason: 'Only offline verification embeds the fixed model fixture',
        );

        final view = await configureModelService(
          handle: host.handle,
          contentsDirectory: contents,
          ipcDirectory: ipc.path,
          osVersion: env['osVersion'] as String,
        );
        expect(view.installed, isFalse);
        controller.publish(view);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ModelPanel(controller: controller),
              ),
            ),
          ),
        );
        await tester.tap(find.text('下载审核模型'));
        await tester.pumpAndSettle();
        expect(find.textContaining(view.modelBytes), findsWidgets);
        await tester.tap(find.text('返回'));
        await tester.pumpAndSettle();
        expect(
          (await inspectModelService(handle: host.handle)).installed,
          isFalse,
        );
        await closeModelDownload(
          handle: host.handle,
          operationId: 'cancelled-before-request',
        );
        await expectLater(
          downloadModel(
            handle: host.handle,
            operationId: 'cancelled-before-request',
          ),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'MODEL_DOWNLOAD_CANCELLED',
            ),
          ),
        );
        if (live) {
          await tester.tap(find.text('下载审核模型'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认下载'));
          final deadline = DateTime.now().add(const Duration(minutes: 21));
          do {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } while (controller.downloading && DateTime.now().isBefore(deadline));
          expect(controller.downloading, isFalse);
          if (controller.error != null) {
            var partialBytes = 0;
            await for (final entity in root.list(
              recursive: true,
              followLinks: false,
            )) {
              if (entity is File && entity.path.endsWith('.part')) {
                partialBytes += await entity.length();
              }
            }
            debugPrint(
              jsonEncode({
                'downloadIssue': controller.error,
                'retainedPartialBytes': partialBytes,
              }),
            );
          }
          expect(controller.error, isNull);
        } else {
          final imported = await importModel(
            handle: host.handle,
            operationId: 'fixed-cache-import',
            selectedFile:
                '$contents/Resources/OrangeModelService/test-model.gguf',
          );
          expect(imported.installed, isTrue);
          await closeModelImport(
            handle: host.handle,
            operationId: 'fixed-cache-import',
          );
          final checked = await downloadModel(
            handle: host.handle,
            operationId: 'cache-hit-download',
          );
          expect(checked.installed, isTrue);
          await closeModelDownload(
            handle: host.handle,
            operationId: 'cache-hit-download',
          );
        }
        final verified = await inspectModelService(handle: host.handle);
        expect(verified.installed, isTrue);
        expect(verified.modelBytes, view.modelBytes);
        expect(verified.phase, anyOf('idle', 'stopped'));
        debugPrint(
          jsonEncode({
            'liveDownload': live,
            'verifiedBytes': verified.modelBytes,
            'dismissalKeptModelAbsent': true,
            'cancelBeforeStart': true,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await closeHost(handle: host.handle);
        await root.delete(recursive: true);
        await ipc.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 24)),
  );
}
