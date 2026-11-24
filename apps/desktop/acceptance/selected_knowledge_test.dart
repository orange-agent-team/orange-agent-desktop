import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/knowledge_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/api/knowledge.dart' as api;
import 'package:orange_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, first, second;
  late host.HostView session;
  late host.WorkspaceView origin, uiSpace;
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['ORANGE_KNOWLEDGE_BRIDGE']!,
      ),
    );
    temp = await Directory.systemTemp.createTemp('orange-desktop-knowledge-');
    first = await Directory('${temp.path}/first').create();
    second = await Directory('${temp.path}/second').create();
    session = await host.initializeHost(
      applicationDataDirectory: '${temp.resolveSymbolicLinksSync()}/host',
    );
    origin = await host.authorizeWorkspace(
      handle: session.handle,
      requestId: 'knowledge-workspace-first',
      selectedDirectory: first.resolveSymbolicLinksSync(),
    );
    uiSpace = await host.authorizeWorkspace(
      handle: session.handle,
      requestId: 'knowledge-workspace-second',
      selectedDirectory: second.resolveSymbolicLinksSync(),
    );
  });
  tearDownAll(() async {
    await host.closeHost(handle: session.handle);
    RustLib.dispose();
    await temp.delete(recursive: true);
  });

  test('native selection binds files, actual OS access session and citation version', () async {
    final path = File('${first.path}/dispatch.txt');
    await path.writeAsString('Copper passes inspection on Friday.');
    await File('${first.path}/other.txt').writeAsString('Hidden source.');
    final binding = api.KnowledgeSelection(
      workspaceId: origin.workspaceId,
      sessionToken: origin.sessionToken!,
      collectionId: 'first-selection',
    );
    Future<void> open(List<String> names) => api.openKnowledgeCollection(
      handle: session.handle,
      selection: binding,
      relativeFiles: names,
    );
    Future<void> rejects(Future<dynamic> task, String code) async {
      try {
        await task;
      } on host.BridgeError catch (e) {
        expect(e.code, code);
        return;
      }
      fail('Expected $code');
    }

    final cancelled = api.KnowledgeSelection(
      workspaceId: origin.workspaceId,
      sessionToken: origin.sessionToken!,
      collectionId: 'cancelled-before-open',
    );
    await api.closeKnowledgeCollection(
      handle: session.handle,
      selection: cancelled,
    );
    await rejects(
      api.openKnowledgeCollection(
        handle: session.handle,
        selection: cancelled,
        relativeFiles: ['dispatch.txt'],
      ),
      'KNOWLEDGE_COLLECTION_CLOSED',
    );
    await open(['dispatch.txt']);
    await open(['dispatch.txt']);
    await rejects(open(['other.txt']), 'KNOWLEDGE_SELECTION_CONFLICT');
    Future<api.KnowledgePage> search(String query) =>
        api.searchSelectedKnowledge(
          handle: session.handle,
          selection: binding,
          query: query,
          limit: 2,
        );
    expect((await search('hidden')).hits, isEmpty);
    final hit = (await search('copper')).hits.single;
    Future<api.KnowledgePassage> read() => api.readKnowledgeCitation(
      handle: session.handle,
      selection: binding,
      hitId: hit.hitId,
      expectedSha256: hit.sourceSha256,
    );
    final replay = await host.authorizeWorkspace(
      handle: session.handle,
      requestId: 'knowledge-workspace-first',
      selectedDirectory: first.resolveSymbolicLinksSync(),
    );
    expect(replay.sessionToken, origin.sessionToken);
    expect((await read()).text, contains('Friday'));
    await path.writeAsString('Copper now passes on Thursday.');
    await rejects(read(), 'KNOWLEDGE_CITATION_STALE');
    expect((await search('Thursday')).hits.single.hitId, isNot(hit.hitId));
    await host.revokeWorkspace(
      handle: session.handle,
      workspaceId: origin.workspaceId,
      expectedVersion: origin.permissionVersion,
    );
    await rejects(search('copper'), 'KNOWLEDGE_ACCESS_DENIED');
    await api.closeKnowledgeCollection(
      handle: session.handle,
      selection: binding,
    );
    await api.closeKnowledgeCollection(
      handle: session.handle,
      selection: binding,
    );
  });
  testWidgets(
    'Flutter searches a real selected file and withdraws displayed text after deletion',
    (tester) async {
      const sentence = '蓝色包裹周四发货。';
      final file = File('${second.path}/shipping.txt')
        ..writeAsStringSync(sentence);
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> visible(Finder f) async {
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (f.evaluate().isEmpty) {
          if (DateTime.now().isAfter(end)) fail('Missing $f');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: KnowledgePanel(
                handle: session.handle,
                workspaces: [uiSpace],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('本地文档检索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(uiSpace.displayPath).last);
      await tester.pumpAndSettle();
      await tester.enterText(field('授权文档'), 'shipping.txt');
      await tester.ensureVisible(find.text('启用所选文档'));
      await tester.tap(find.text('启用所选文档'));
      await tester.pump();
      await visible(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == '查找内容' &&
              w.enabled == true,
        ),
      );
      await tester.enterText(field('查找内容'), '周四发货');
      await tester.pump();
      await tester.ensureVisible(find.text('检索所选文档'));
      await tester.tap(find.text('检索所选文档'));
      await tester.pump();
      final row = find.widgetWithText(ListTile, 'shipping.txt');
      await visible(row);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await visible(find.text(sentence));
      expect(find.textContaining('SHA-256 '), findsOneWidget);
      file.deleteSync();
      await tester.pump(const Duration(seconds: 3));
      await visible(find.text('来源已变化，请重新检索。'));
      expect(find.text(sentence), findsNothing);
      expect(row, findsNothing);
      await tester.tap(find.text('关闭文档集合'));
      await tester.pump();
      expect(find.text('启用所选文档'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
