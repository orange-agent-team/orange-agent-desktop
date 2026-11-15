import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/memory_controller.dart';
import 'package:orange_desktop/memory_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/api/memory.dart' as api;
import 'package:orange_desktop/src/rust/frb_generated.dart';

Future<host.HostView> reopen(String path) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    try {
      return await host.initializeHost(applicationDataDirectory: path);
    } on host.BridgeError catch (e) {
      if (e.code != 'HOST_BUSY' || DateTime.now().isAfter(end)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 30),
  );
}

Widget app(MemoryController controller) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffed6b2d)),
  ),
  home: RepaintBoundary(
    key: const Key('native-memory-snapshot'),
    child: Scaffold(
      body: SingleChildScrollView(
        child: MemoryPanel(controller: controller, workspaces: const []),
      ),
    ),
  ),
);
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.init());
  testWidgets(
    'native memory manager uses actual FRB approval, full Unicode reads and persistent SQLite',
    (tester) async {
      final private = await Directory.systemTemp.createTemp(
        'orange-memory-native-',
      );
      MemoryController? controller;
      String? handle;
      bool passed = false;
      String? screenshot;
      try {
        final opened = await reopen(private.path);
        handle = opened.handle;
        controller = MemoryController(NativeMemoryCommands(handle));
        await controller.refresh();
        await tester.pumpWidget(app(controller));
        await settle(tester);
        await tap(tester, find.text('新建空间'));
        await tester.enterText(
          find.byKey(const Key('memory-scope-id')),
          'native-memory',
        );
        await tap(tester, find.text('创建'));
        expect(controller.scopes.single.scopeId, 'native-memory');
        expect(controller.access, isNull);
        await controller.chooseScope('native-memory');
        await settle(tester);
        await tap(tester, find.text('打开编辑访问'));
        expect(controller.canWrite, isTrue);
        await tap(tester, find.text('新增记忆'));
        final body = '真实本地记忆：${'甲乙' * 2500}';
        await tester.enterText(find.byKey(const Key('memory-title')), '真实本地记忆');
        await tester.enterText(find.byKey(const Key('memory-content')), body);
        await tap(tester, find.byKey(const Key('memory-preview')));
        expect(controller.preview, isNotNull);
        final pending = await api.inspectEdit(
          handle: handle,
          scopeId: 'native-memory',
          requestId: controller.pendingRequest!,
        );
        expect(pending!.state, 'pending');
        expect(
          (await api.listEntries(
            handle: handle,
            selection: controller.selection!,
            limit: 30,
            includeDisabled: false,
          )).entries,
          isEmpty,
        );
        await tap(tester, find.byKey(const Key('memory-confirm')));
        expect(controller.receipt!.state, 'approved');
        final id = controller.receipt!.entryId;
        expect(controller.entries.single.entryId, id);
        await tap(tester, find.byKey(ValueKey('memory-entry-$id')));
        expect(controller.entry!.content, body);
        expect(
          controller.entry!.totalBytes,
          utf8.encode(body).length.toString(),
        );
        expect(controller.entry!.nextByte, isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('native-memory-snapshot')),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        expect(png, isNotNull);
        final visual = await Directory.systemTemp.createTemp(
          'orange-memory-visual-',
        );
        screenshot = '${visual.path}/memory-manager.png';
        await File(screenshot).writeAsBytes(png!.buffer.asUint8List());
        final old = controller.selection!;
        await tap(tester, find.text('关闭访问'));
        expect(controller.entry, isNull);
        expect(controller.preview, isNull);
        expect(controller.access, isNull);
        await expectLater(
          api.readEntry(
            handle: handle,
            selection: old,
            entryId: id,
            startByte: 0,
            maxBytes: 4096,
            includeDisabled: false,
          ),
          throwsA(isA<host.BridgeError>()),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.closeAccess();
        controller.dispose();
        controller = null;
        await host.closeHost(handle: handle);
        handle = null;
        final restored = await reopen(private.path);
        handle = restored.handle;
        controller = MemoryController(NativeMemoryCommands(handle));
        await controller.refresh();
        expect(controller.scopes.single.sessionToken, isNull);
        await controller.chooseScope('native-memory');
        await tester.pumpWidget(app(controller));
        await settle(tester);
        await tap(tester, find.text('打开只读访问'));
        expect(controller.canWrite, isFalse);
        await tap(tester, find.byKey(ValueKey('memory-entry-$id')));
        expect(controller.entry!.content, body);
        expect(find.byKey(const Key('memory-preview')), findsNothing);
        await expectLater(
          api.prepareEdit(
            handle: handle,
            selection: controller.selection!,
            edit: api.MemoryEdit(
              requestId: 'readonly-probe',
              entryId: id,
              expectedVersion: '1',
              delete: false,
              title: 'Denied',
              content: 'Must not commit',
              enabled: true,
            ),
          ),
          throwsA(isA<host.BridgeError>()),
        );
        debugPrint(
          jsonEncode({
            'nativeMemory': true,
            'typedFrb': true,
            'explicitUiApproval': true,
            'fullUnicodeBytes': utf8.encode(body).length,
            'closedSelectionRejected': true,
            'reopenRequiredExplicitGrant': true,
            'persistedAfterReopen': true,
            'readonlyWriteRejected': true,
            'modelInference': false,
            'screenshot': screenshot,
          }),
        );
        passed = true;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (controller != null) {
          await controller.closeAccess();
          controller.dispose();
        }
        if (handle != null) await host.closeHost(handle: handle);
        if (passed) await private.delete(recursive: true);
      }
    },
  );
}
