import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/memory_controller.dart';
import 'package:orange_desktop/memory_panel.dart';
import 'package:orange_desktop/src/rust/api/memory.dart' as api;
import 'package:orange_desktop/src/rust/api/host.dart' show BridgeError;

// Explicit UI transport fixture. Native SQLite/source/drain tests are separate.
class MemoryFixture implements MemoryCommands {
  static const scope = api.MemoryScopeView(
    scopeId: 'personal',
    owner: 'owner',
    shared: false,
    revision: '1',
    enabled: true,
    access: 'write',
    canAdminister: true,
    sessionWrite: false,
  );
  List<api.MemoryScopeView> scopeRows = [scope];
  final released = <String>[];
  int approvals = 0, prepares = 0, reads = 0;
  String? requestedToken;
  Completer<api.MemoryAccessView>? authorizationGate;
  Completer<api.MemoryEntry>? readGate;
  String body = 'Jasmine tea';
  bool incomplete = false, loseReply = false;
  api.MemoryReview? pending;
  api.MemoryOutcome? committed;
  @override
  Future<api.MemoryScopePage> scopes(String? cursor) async =>
      api.MemoryScopePage(scopes: scopeRows);
  @override
  Future<api.MemoryScopeView> create(String id, bool shared) async => scope;
  @override
  Future<api.MemoryAccessView> authorize(
    api.MemoryScopeView scope,
    String token,
    bool write,
  ) {
    requestedToken = token;
    return authorizationGate?.future ??
        Future.value(
          api.MemoryAccessView(
            scopeId: scope.scopeId,
            revision: scope.revision,
            sessionToken: token,
            write: write,
          ),
        );
  }

  @override
  Future<api.MemoryMemberPage> members(
    api.MemoryScopeView scope,
    String? cursor,
  ) async => api.MemoryMemberPage(
    scopeId: scope.scopeId,
    revision: scope.revision,
    members: const [api.MemoryMemberView(principal: 'owner', access: 'write')],
  );
  @override
  Future<api.MemoryScopeView> member(
    api.MemoryScopeView scope,
    String principal,
    String access,
  ) async => scope;
  @override
  Future<void> release(String token) async {
    released.add(token);
  }

  @override
  Future<api.MemoryScopeView> enable(
    api.MemoryScopeView scope,
    bool enabled,
  ) async => scope;
  @override
  Future<api.MemoryPage> entries(
    api.MemorySelection selected,
    String? cursor,
    bool disabled,
  ) async => api.MemoryPage(
    scopeId: selected.scopeId,
    entries: committed == null
        ? []
        : [
            api.MemorySummary(
              entryId: committed!.entryId,
              version: committed!.resultVersion!,
              title: pending!.title!,
              enabled: true,
              origin: 'user_declaration',
              contentBytes: utf8.encode(pending!.content!).length.toString(),
            ),
          ],
    omittedUnavailable: false,
    scanLimited: false,
  );
  api.MemoryEntry part(String id, String version, int start) {
    final bytes = utf8.encode(body);
    int end = start + 4096;
    if (end > bytes.length) end = bytes.length;
    while (end < bytes.length && (bytes[end] & 0xc0) == 0x80) {
      end--;
    }
    return api.MemoryEntry(
      scopeId: 'personal',
      entryId: id,
      version: version,
      title: 'Note',
      content: utf8.decode(bytes.sublist(start, end)),
      enabled: true,
      origin: 'user_declaration',
      sourceActor: 'owner',
      sourceRun: 'fixture',
      totalBytes: (bytes.length + (incomplete ? 1 : 0)).toString(),
      startByte: start.toString(),
      nextByte: end < bytes.length ? end.toString() : null,
    );
  }

  @override
  Future<api.MemoryEntry> read(
    api.MemorySelection selected,
    String id,
    String version,
    int start,
  ) {
    reads++;
    return readGate?.future ?? Future.value(part(id, version, start));
  }

  @override
  Future<api.MemoryReview> prepare(
    api.MemorySelection selected,
    api.MemoryEdit edit,
  ) async {
    prepares++;
    pending = api.MemoryReview(
      draftId: 'draft-$prepares',
      scopeId: selected.scopeId,
      entryId: edit.entryId,
      expectedVersion: edit.expectedVersion,
      approvalDigest: 'a' * 64,
      sourceRun: 'fixture-human',
      title: edit.title,
      content: edit.content,
      enabled: edit.enabled,
      delete: edit.delete,
      expiresAt: '9999999999',
    );
    return pending!;
  }

  @override
  Future<api.MemoryReview> review(
    api.MemorySelection selected,
    String draft,
  ) async => pending!;
  @override
  Future<api.MemoryOutcome> approve(
    api.MemorySelection selected,
    api.MemoryReview review,
  ) async {
    approvals++;
    committed = api.MemoryOutcome(
      draftId: review.draftId,
      scopeId: review.scopeId,
      entryId: review.entryId,
      digest: 'b' * 64,
      state: 'approved',
      resultVersion: ((int.tryParse(review.expectedVersion ?? '0') ?? 0) + 1)
          .toString(),
    );
    if (loseReply) {
      throw const BridgeError(
        code: 'MEMORY_STORAGE_UNAVAILABLE',
        correlationId: 'fixture',
      );
    }
    return committed!;
  }

  @override
  Future<api.MemoryOutcome?> outcome(String scope, String request) async =>
      committed;
}

Future<MemoryController> ready(MemoryFixture commands) async {
  int serial = 0;
  final c = MemoryController(commands, token: () => 'token-${++serial}');
  await c.refresh();
  await c.chooseScope('personal');
  await c.open(write: true);
  return c;
}

const summary = api.MemorySummary(
  entryId: 'entry',
  version: '1',
  title: 'Note',
  enabled: true,
  origin: 'user_declaration',
  contentBytes: '11',
);
void main() {
  test('complete UTF8 body is loaded before editing and partial reads cannot become saved replacements', () async {
    final commands = MemoryFixture()..body = '${'甲' * 1365}${'乙' * 1000}';
    final c = await ready(commands);
    await c.readEntry(summary);
    expect(c.entry!.content, commands.body);
    expect(commands.reads, 2);
    expect(c.targetVersion, '1');
    commands.incomplete = true;
    await c.readEntry(summary);
    expect(c.entry, isNull);
    expect(c.targetVersion, isNull);
    expect(c.error, isNotNull);
    expect(commands.prepares, 0);
    c.dispose();
  });
  test(
    'closing access clears content and rejects a late read response',
    () async {
      final commands = MemoryFixture();
      final c = await ready(commands);
      commands.readGate = Completer();
      final read = c.readEntry(summary);
      await Future<void>.delayed(Duration.zero);
      await c.closeAccess();
      commands.readGate!.complete(commands.part('entry', '1', 0));
      await read;
      expect(c.entry, isNull);
      expect(c.preview, isNull);
      expect(c.selection, isNull);
      expect(commands.released, isNotEmpty);
      c.dispose();
    },
  );
  test('late authorization cannot restore a closed selection', () async {
    final commands = MemoryFixture()..authorizationGate = Completer();
    final c = MemoryController(commands, token: () => 'late-token');
    await c.refresh();
    await c.chooseScope('personal');
    final opening = c.open(write: true);
    await Future<void>.delayed(Duration.zero);
    await c.closeAccess();
    commands.authorizationGate!.complete(
      const api.MemoryAccessView(
        scopeId: 'personal',
        revision: '1',
        sessionToken: 'late-token',
        write: true,
      ),
    );
    await opening;
    expect(c.access, isNull);
    expect(c.selection, isNull);
    expect(commands.released, contains('late-token'));
    c.dispose();
  });
  test('a lost approval reply is recovered by metadata and never automatically replayed', () async {
    final commands = MemoryFixture()..loseReply = true;
    final c = await ready(commands);
    c.beginNew();
    await c.prepare(title: 'Tea', content: 'Owned declaration', enabled: true);
    expect(commands.approvals, 0);
    await c.approve();
    expect(c.preview, isNull);
    expect(c.error, isNotNull);
    await c.inspectPending();
    expect(c.receipt!.state, 'approved');
    expect(commands.approvals, 1);
    await c.approve();
    expect(commands.approvals, 1);
    c.dispose();
  });
  test('an already committed response arriving after close is recovered without replay', () async {
    final commands = MemoryFixture();
    final c = await ready(commands);
    c.beginNew();
    await c.prepare(title: 'Tea', content: 'Owned declaration', enabled: true);
    final approval = c.approve();
    await c.closeAccess();
    await approval;
    expect(c.preview, isNull);
    expect(c.entry, isNull);
    await c.inspectPending();
    expect(c.receipt!.state, 'approved');
    expect(commands.approvals, 1);
    c.dispose();
  });
  test(
    'source closure hides a loaded entry and invalidates its review',
    () async {
      final commands = MemoryFixture();
      final c = await ready(commands);
      await c.setSourceWorkspace('source', true);
      await c.readEntry(summary);
      await c.prepare(
        title: 'Confirmed',
        content: 'Known source text',
        enabled: true,
      );
      expect(c.preview, isNotNull);
      final before = c.visibilityEpoch;
      c.workspaceStopping('source');
      expect(c.visibilityEpoch, greaterThan(before));
      expect(c.entry, isNull);
      expect(c.preview, isNull);
      expect(c.sourceWorkspaces, isEmpty);
      expect(commands.approvals, 0);
      c.dispose();
    },
  );
  testWidgets(
    'switching shared scope resets member identity and permission mode',
    (tester) async {
      api.MemoryScopeView shared(String id) => api.MemoryScopeView(
        scopeId: id,
        owner: 'owner',
        shared: true,
        revision: '1',
        enabled: true,
        access: 'write',
        canAdminister: true,
        sessionWrite: false,
      );
      final commands = MemoryFixture()..scopeRows = [shared('a'), shared('b')];
      final c = MemoryController(commands);
      await c.refresh();
      await c.chooseScope('a');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MemoryPanel(controller: c, workspaces: const []),
            ),
          ),
        ),
      );
      await tester.tap(find.text('共享成员权限'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('memory-principal')));
      await tester.enterText(find.byKey(const Key('memory-principal')), 'bob');
      await tester.ensureVisible(find.byKey(const Key('memory-member-access')));
      await tester.tap(find.byKey(const Key('memory-member-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读写').last);
      await tester.pumpAndSettle();
      await c.chooseScope('b');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('memory-principal')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('memory-member-access')),
            )
            .value,
        'read',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  testWidgets(
    'actual confirmation button is required after the immutable preview',
    (tester) async {
      final commands = MemoryFixture();
      final c = MemoryController(
        commands,
        token: () {
          return 'ui-${DateTime.now().microsecondsSinceEpoch}';
        },
      );
      await c.refresh();
      await c.chooseScope('personal');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MemoryPanel(controller: c, workspaces: const []),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑访问'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('新增记忆'));
      await tester.tap(find.text('新增记忆'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('memory-title')), 'Tea');
      await tester.enterText(
        find.byKey(const Key('memory-content')),
        'Owned UI declaration',
      );
      await tester.ensureVisible(find.byKey(const Key('memory-preview')));
      await tester.tap(find.byKey(const Key('memory-preview')));
      await tester.pumpAndSettle();
      expect(commands.prepares, 1);
      expect(commands.approvals, 0);
      expect(find.text('保存预览'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('memory-confirm')));
      await tester.tap(find.byKey(const Key('memory-confirm')));
      await tester.pumpAndSettle();
      expect(commands.approvals, 1);
      expect(find.text('保存已确认。'), findsOneWidget);
      expect(c.preview, isNull);
      await tester.ensureVisible(find.text('关闭访问'));
      await tester.tap(find.text('关闭访问'));
      await tester.pumpAndSettle();
      expect(find.text('Owned UI declaration'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
