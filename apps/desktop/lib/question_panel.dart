import 'dart:convert';

import 'package:flutter/material.dart';

import 'src/rust/api/host.dart';

/// Drafts exist only while this exact authorized question is visible.
class QuestionPanel extends StatefulWidget {
  const QuestionPanel({
    super.key,
    required this.question,
    required this.busy,
    required this.onSubmit,
  });
  final UserQuestionGroupView question;
  final bool busy;
  final Future<void> Function(List<String>) onSubmit;
  @override
  State<QuestionPanel> createState() => _QuestionPanelState();
}

class _QuestionPanelState extends State<QuestionPanel> {
  late final List<TextEditingController> answers;
  @override
  void initState() {
    super.initState();
    answers = List.generate(
      widget.question.questions.length,
      (_) => TextEditingController(),
    );
  }

  @override
  void dispose() {
    for (final answer in answers) {
      answer.dispose();
    }
    super.dispose();
  }

  String? invalid(String text) {
    if (text.contains('\u0000')) return '回答含有不支持的字符。';
    if (utf8.encode(text).length > 4096) return '回答过长，请缩短内容（最多 4096 UTF-8 字节）。';
    return null;
  }

  bool get valid =>
      answers.isNotEmpty &&
      answers.every((a) => a.text.trim().isNotEmpty && invalid(a.text) == null);
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('需要补充信息', style: Theme.of(context).textTheme.titleMedium),
          const Text('回答用于继续任务。后续工具操作仍会单独请求批准。'),
          for (var i = 0; i < widget.question.questions.length; i++) ...[
            const SizedBox(height: 12),
            Text(widget.question.questions[i].prompt),
            if (widget.question.questions[i].choices != null)
              Wrap(
                spacing: 8,
                children: [
                  for (final choice in widget.question.questions[i].choices!)
                    OutlinedButton(
                      onPressed: widget.busy
                          ? null
                          : () => setState(() {
                              answers[i].text = choice;
                            }),
                      child: Text(choice),
                    ),
                ],
              ),
            TextField(
              key: ValueKey('question-answer-$i'),
              controller: answers[i],
              readOnly: widget.busy,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '回答 ${i + 1}',
                hintText: '可选择建议或自行填写',
                errorText: invalid(answers[i].text),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: widget.busy || !valid
                ? null
                : () => widget.onSubmit(answers.map((a) => a.text).toList()),
            child: const Text('提交回答'),
          ),
        ],
      ),
    ),
  );
}
