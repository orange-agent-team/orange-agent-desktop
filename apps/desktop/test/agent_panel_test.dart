import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/agent_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

// Explicit UI transport substitute; Rust/native/model acceptance is separate.
class FixtureCommands implements AgentCommands {
  final events = <String>[];
  final starts = <({String id, String prompt})>[];
  String id = 'fixture-run';
  CreationAccessView? creationAccess;
  final creationStarts = <String?>[];
  bool? approvedAsCreation;
  String toolName = 'read_file';
  String argumentsJson = '{"path":"proof.txt"}';
  int transition = 0;
  bool approved = false, rejectApproval = false, uncertainStart = false;
  Completer<AgentRunView>? advanceGate, inspectGate;
  AgentRunView state(
    String phase, {
    int steps = 0,
    List<ToolApprovalView> pending = const [],
    String? text,
  }) => AgentRunView(
    creationConsentId: creationAccess?.consentId,
    runId: id,
    workspaceId: 'fixture-workspace',
    modelId: 'fixture-model',
    phase: phase,
    revision: '$phase:$steps',
    steps: steps,
    invocations: steps > 1 ? 2 : 1,
    pending: pending,
    finalText: text,
  );
  @override
  Future<ModelConnectionView> connect(String directory) async {
    events.add('connect');
    return const ModelConnectionView(
      modelId: 'fixture-model',
      displayName: '明确模型替身',
      contextTokens: 4096,
      verification: 'test-fixture',
    );
  }

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
  }

  @override
  Future<AgentRunView> start(
    String workspace,
    String request,
    String prompt, {
    bool allowQuestions = false,
    CreationAccessView? creation,
  }) async {
    events.add('start');
    creationAccess = creation;
    creationStarts.add(
      creation == null
          ? null
          : '${creation.consentId}:${creation.permissionVersion}',
    );
    id = request;
    starts.add((id: request, prompt: prompt));
    if (uncertainStart) {
      uncertainStart = false;
      throw StateError('explicit lost response after fixture commit');
    }
    return state('ready');
  }

  @override
  Future<AgentRunView> inspect(String request) async {
    events.add('inspect');
    return inspectGate?.future ??
        state('completed', steps: 3, text: 'fixture result');
  }

  @override
  Future<AgentRunView> approve(
    String request,
    String operation,
    String digest, {
    bool create = false,
  }) async {
    events.add('approve');
    approvedAsCreation = create;
    expect(operation, 'fixture-operation');
    expect(digest, 'fixture-digest');
    if (rejectApproval) {
      throw const BridgeError(
        code: 'TOOL_PREVIEW_CHANGED',
        correlationId: 'fixture',
      );
    }
    approved = true;
    return state('tools_pending', steps: 1);
  }

  @override
  Future<AgentRunView> answer(
    String request,
    String question,
    String digest,
    List<String> answers,
  ) async {
    throw StateError('Question transport is not configured in this fixture');
  }

  @override
  Future<AgentRunView> advance(String request, String revision) async {
    events.add('advance');
    if (advanceGate != null) return advanceGate!.future;
    transition++;
    if (transition == 1) {
      return state(
        'tools_pending',
        steps: 1,
        pending: [
          ToolApprovalView(
            operationId: 'fixture-operation',
            toolName: toolName,
            argumentsJson: argumentsJson,
            argumentDigest: 'fixture-digest',
          ),
        ],
      );
    }
    expect(
      approved,
      isTrue,
      reason: 'UI must not advance a proposed tool without user action',
    );
    if (transition == 2) return state('ready', steps: 2);
    return state('completed', steps: 3, text: 'fixture result');
  }

  @override
  Future<AgentRunView> cancel(String request) async {
    events.add('cancel');
    return state('cancelled');
  }
}

const workspace = WorkspaceView(
  workspaceId: 'fixture-workspace',
  displayPath: '/owned/fixture',
  permissionVersion: '1',
  permissionActive: true,
  sessionAccess: true,
  sessionToken: 'fixture-scope',
);
Future<AgentController> show(
  WidgetTester tester,
  FixtureCommands commands, {
  List<CreationAccessView> creations = const [],
}) async {
  tester.view.resetPhysicalSize();
  tester.view.physicalSize = const Size(1100, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = AgentController(
    commands,
    serviceDirectory: () async => '/private/fixture-service',
  );
  addTearDown(controller.dispose);
  await controller.connect();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AgentPanel(
            controller: controller,
            workspaces: const [workspace],
            creations: creations,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('/owned/fixture').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'Read proof.txt');
  await tester.pump();
  expect(
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '开始会话'))
        .onPressed,
    isNotNull,
  );
  await tester.tap(find.text('开始会话'));
  await tester.pumpAndSettle();
}

const createAccess = CreationAccessView(
  consentId: 'create-consent',
  workspaceId: 'fixture-workspace',
  displayPath: '/owned/fixture',
  permissionVersion: '1',
  permissionActive: true,
  sessionToken: 'write-token',
);

void main() {
  testWidgets(
    'creation is default off and exact content uses separate approval',
    (tester) async {
      final commands = FixtureCommands()
        ..toolName = 'write_file'
        ..argumentsJson = '{"path":"new.txt","content":"line one\\nline two"}';
      final controller = await show(
        tester,
        commands,
        creations: const [createAccess],
      );
      final checkbox = find.widgetWithText(CheckboxListTile, '允许提出新建文件请求');
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await controller.start(
        workspace.workspaceId,
        'Create new.txt',
        creation: createAccess,
      );
      await tester.pumpAndSettle();
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.text('line one\nline two'), findsOneWidget);
      expect(commands.events.where((e) => e == 'approve'), isEmpty);
      await tester.ensureVisible(find.text('批准新建这个文件'));
      await tester.tap(find.text('批准新建这个文件'));
      await tester.pumpAndSettle();
      expect(commands.approvedAsCreation, isTrue);
      expect(controller.view!.phase, 'completed');
      controller.creationStopping('unrelated-consent');
      expect(controller.view, isNotNull);
      controller.creationStopping(createAccess.consentId);
      expect(controller.view, isNull);
    },
  );
  testWidgets(
    'creation retry keeps exact consent and malformed preview cannot be approved',
    (tester) async {
      final commands = FixtureCommands()
        ..uncertainStart = true
        ..toolName = 'write_file'
        ..argumentsJson = '{"path":"new.txt","content":false}';
      final controller = await show(
        tester,
        commands,
        creations: const [createAccess],
      );
      await controller.start(
        workspace.workspaceId,
        'Create',
        creation: createAccess,
      );
      expect(controller.startUnconfirmed, isTrue);
      await controller.retryStart();
      await tester.pumpAndSettle();
      expect(commands.creationStarts, ['create-consent:1', 'create-consent:1']);
      expect(controller.supportedPreview, isFalse);
      await controller.approveFirst();
      expect(commands.events.where((e) => e == 'approve'), isEmpty);
    },
  );
  for (final entry in <String, String>{
    'search_files': '{"path":".","glob":"**/*.rs","limit":20}',
    'search_text':
        '{"path":"src","query":"token","regular_expression":false,"limit":10}',
  }.entries) {
    testWidgets(
      '${entry.key} displays the exact search preview and requires one explicit approval',
      (tester) async {
        final commands = FixtureCommands()
          ..toolName = entry.key
          ..argumentsJson = entry.value;
        final controller = await show(tester, commands);
        await submit(tester);
        expect(controller.supportedPreview, isTrue);
        expect(find.text(toolDisplayName(entry.key)), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        expect(commands.events, ['connect', 'start', 'advance']);
        await tester.ensureVisible(find.text('批准这一次搜索'));
        await tester.tap(find.text('批准这一次搜索'));
        await tester.pumpAndSettle();
        expect(commands.events, [
          'connect',
          'start',
          'advance',
          'approve',
          'advance',
          'advance',
        ]);
        expect(commands.events.where((event) => event == 'approve').length, 1);
        expect(find.text('fixture result'), findsOneWidget);
      },
    );
    testWidgets(
      '${entry.key} cannot advance after its approved preview was rejected',
      (tester) async {
        final commands = FixtureCommands()
          ..toolName = entry.key
          ..argumentsJson = entry.value
          ..rejectApproval = true;
        final controller = await show(tester, commands);
        await submit(tester);
        await tester.ensureVisible(find.text('批准这一次搜索'));
        await tester.tap(find.text('批准这一次搜索'));
        await tester.pumpAndSettle();
        expect(controller.view, isNull);
        expect(commands.events.where((event) => event == 'advance').length, 1);
        expect(find.text(entry.value), findsNothing);
        expect(find.text('fixture result'), findsNothing);
      },
    );
  }
  for (final unsupported in {
    'write_file': '批准新建这个文件',
    'future_tool': '批准这一次读取',
  }.entries) {
    testWidgets('${unsupported.key} cannot inherit a readonly approval UI', (
      tester,
    ) async {
      final commands = FixtureCommands()..toolName = unsupported.key;
      final controller = await show(tester, commands);
      await submit(tester);
      expect(controller.supportedPreview, isFalse);
      await controller.approveFirst();
      expect(commands.events, ['connect', 'start', 'advance']);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, unsupported.value),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('无法批准此工具权限'), findsOneWidget);
    });
  }
  testWidgets(
    'proposal stops at an immutable preview until the actual approve button is pressed',
    (tester) async {
      final commands = FixtureCommands();
      await show(tester, commands);
      await submit(tester);
      expect(commands.events, ['connect', 'start', 'advance']);
      expect(find.text('{"path":"proof.txt"}'), findsOneWidget);
      expect(find.text('fixture result'), findsNothing);
      await tester.ensureVisible(find.text('批准这一次读取'));
      await tester.tap(find.text('批准这一次读取'));
      await tester.pumpAndSettle();
      expect(commands.events, [
        'connect',
        'start',
        'advance',
        'approve',
        'advance',
        'advance',
      ]);
      expect(find.text('fixture result'), findsOneWidget);
    },
  );
  testWidgets(
    'stop remains usable during model wait and suppresses a late completed response',
    (tester) async {
      final commands = FixtureCommands()
        ..advanceGate = Completer<AgentRunView>();
      final controller = await show(tester, commands);
      final running = controller.start(workspace.workspaceId, 'Wait');
      await tester.pump();
      expect(controller.busy, isTrue);
      await tester.tap(find.text('停止会话'));
      await tester.pump();
      expect(commands.events, contains('cancel'));
      commands.advanceGate!.complete(
        commands.state('completed', text: 'late forbidden result'),
      );
      await running;
      await tester.pumpAndSettle();
      expect(find.text('late forbidden result'), findsNothing);
      expect(controller.view!.phase, 'cancelled');
      expect(commands.events.where((e) => e == 'advance').length, 1);
    },
  );
  testWidgets(
    'uncertain creation retries the original identity and immutable prompt',
    (tester) async {
      final commands = FixtureCommands()..uncertainStart = true;
      final controller = await show(tester, commands);
      await submit(tester);
      expect(controller.startUnconfirmed, isTrue);
      expect(
        (tester.widget<TextField>(find.byType(TextField))).readOnly,
        isTrue,
      );
      await tester.tap(find.text('核对创建结果'));
      await tester.pumpAndSettle();
      expect(commands.starts.length, 2);
      expect(commands.starts[0], commands.starts[1]);
      expect(commands.events.where((e) => e == 'advance').length, 1);
      expect(controller.startUnconfirmed, isFalse);
    },
  );
  testWidgets(
    'changed approval preview clears stale content and cannot execute a tool',
    (tester) async {
      final commands = FixtureCommands()..rejectApproval = true;
      final controller = await show(tester, commands);
      await submit(tester);
      await tester.ensureVisible(find.text('批准这一次读取'));
      await tester.tap(find.text('批准这一次读取'));
      await tester.pumpAndSettle();
      expect(commands.events.where((e) => e == 'advance').length, 1);
      expect(controller.view, isNull);
      expect(find.text('{"path":"proof.txt"}'), findsNothing);
      expect(find.textContaining('操作内容或版本已改变'), findsOneWidget);
    },
  );
  testWidgets(
    'recovered content is hidden before refresh and remains hidden when source authorization fails',
    (tester) async {
      final commands = FixtureCommands();
      final controller = await show(tester, commands);
      await controller.load('fixture-run');
      await tester.pumpAndSettle();
      expect(find.text('fixture result'), findsOneWidget);
      commands.inspectGate = Completer<AgentRunView>();
      final loading = controller.load('fixture-run');
      await tester.pump();
      expect(find.text('fixture result'), findsNothing);
      commands.inspectGate!.completeError(
        const BridgeError(
          code: 'RUN_SOURCE_UNAVAILABLE',
          correlationId: 'fixture',
        ),
      );
      await loading;
      await tester.pumpAndSettle();
      expect(find.text('fixture result'), findsNothing);
      expect(find.textContaining('来源文件已改变'), findsOneWidget);
    },
  );
}
