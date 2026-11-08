import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/question_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

import 'agent_panel_test.dart' as base;

const question = UserQuestionGroupView(
  questionId: 'fixture-question',
  argumentDigest: 'fixture-question-digest',
  questions: [
    UserQuestionView(prompt: 'Which file?', choices: ['note.txt', 'other.txt']),
  ],
);

class QuestionCommands extends base.FixtureCommands {
  final replies = <List<String>>[];
  bool replied = false;
  Completer<AgentRunView>? replyGate;
  AgentRunView waiting() => AgentRunView(
    runId: id,
    workspaceId: 'fixture-workspace',
    modelId: 'fixture-model',
    phase: 'awaiting_user',
    revision: 'question:1',
    steps: 1,
    invocations: 1,
    pending: const [],
    userQuestion: question,
  );
  @override
  Future<AgentRunView> start(
    String workspace,
    String request,
    String prompt, {
    bool allowQuestions = false,
    CreationAccessView? creation,
  }) async {
    expect(
      allowQuestions,
      isTrue,
      reason: 'Questions require explicit creation capability',
    );
    return super.start(
      workspace,
      request,
      prompt,
      allowQuestions: allowQuestions,
      creation: creation,
    );
  }

  @override
  Future<AgentRunView> advance(String request, String revision) async {
    if (!replied) {
      events.add('question');
      return waiting();
    }
    return super.advance(request, revision);
  }

  @override
  Future<AgentRunView> inspect(String request) async {
    events.add('inspect');
    return waiting();
  }

  @override
  Future<AgentRunView> answer(
    String request,
    String questionId,
    String digest,
    List<String> answers,
  ) async {
    events.add('answer');
    replies.add(List.of(answers));
    expect(questionId, question.questionId);
    expect(digest, question.argumentDigest);
    replied = true;
    return replyGate?.future ?? state('ready', steps: 2);
  }
}

void main() {
  testWidgets('all three prompts require answers before submission', (
    tester,
  ) async {
    final received = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionPanel(
            question: const UserQuestionGroupView(
              questionId: 'three',
              argumentDigest: 'digest',
              questions: [
                UserQuestionView(prompt: 'First'),
                UserQuestionView(prompt: 'Second'),
                UserQuestionView(prompt: 'Third'),
              ],
            ),
            busy: false,
            onSubmit: (answers) async {
              received.add(answers);
            },
          ),
        ),
      ),
    );
    final send = find.widgetWithText(FilledButton, '提交回答');
    for (var i = 0; i < 3; i++) {
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byKey(ValueKey('question-answer-$i')),
        'Answer $i',
      );
      await tester.pump();
    }
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pump();
    expect(received.single, ['Answer 0', 'Answer 1', 'Answer 2']);
  });
  testWidgets(
    'suggestions are editable and answering still stops for separate approval',
    (tester) async {
      final commands = QuestionCommands();
      await base.show(tester, commands);
      await tester.ensureVisible(find.text('允许任务询问补充信息'));
      await tester.tap(find.text('允许任务询问补充信息'));
      await tester.pump();
      await base.submit(tester);
      expect(find.text('等待你的回答 · 1 步'), findsOneWidget);
      expect(commands.events.where((e) => e == 'question').length, 1);
      final send = find.widgetWithText(FilledButton, '提交回答');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, 'other.txt'),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'other.txt'));
      await tester.pump();
      expect(commands.replies, isEmpty);
      final field = find.byKey(const ValueKey('question-answer-0'));
      await tester.enterText(field, 'a freely supplied filename.txt');
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(commands.replies.single, ['a freely supplied filename.txt']);
      expect(commands.events, isNot(contains('approve')));
      expect(find.text('需要你的批准'), findsOneWidget);
      expect(find.text('提交回答'), findsNothing);
    },
  );
  testWidgets(
    'UTF8 bound rejects oversized answers and does not truncate user input',
    (tester) async {
      final commands = QuestionCommands();
      await base.show(tester, commands);
      await tester.ensureVisible(find.text('允许任务询问补充信息'));
      await tester.tap(find.text('允许任务询问补充信息'));
      await tester.pump();
      await base.submit(tester);
      final field = find.byKey(const ValueKey('question-answer-0'));
      await tester.enterText(field, List.filled(1366, '中').join());
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
            .onPressed,
        isNull,
      );
      expect(commands.replies, isEmpty);
      await tester.enterText(field, List.filled(1365, '中').join());
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答'))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'hiding authority clears drafts and late answer response cannot revive cancelled content',
    (tester) async {
      final commands = QuestionCommands();
      final controller = await base.show(tester, commands);
      await tester.ensureVisible(find.text('允许任务询问补充信息'));
      await tester.tap(find.text('允许任务询问补充信息'));
      await tester.pump();
      await base.submit(tester);
      final field = find.byKey(const ValueKey('question-answer-0'));
      await tester.enterText(field, 'private draft');
      await tester.pump();
      controller.hideContent();
      await tester.pump();
      expect(find.text('Which file?'), findsNothing);
      expect(find.text('private draft'), findsNothing);
      await controller.load(controller.runId!);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      commands.replyGate = Completer<AgentRunView>();
      await tester.enterText(field, 'note.txt');
      await tester.pump();
      final send = find.widgetWithText(FilledButton, '提交回答');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await controller.cancel();
      await tester.pump();
      commands.replyGate!.complete(commands.state('ready', steps: 2));
      await tester.pumpAndSettle();
      expect(controller.view!.phase, 'cancelled');
      expect(commands.events, isNot(contains('approve')));
      expect(commands.events.where((e) => e == 'advance'), isEmpty);
      expect(find.text('Which file?'), findsNothing);
    },
  );
}
