import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/agent_controller.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

import 'agent_panel_test.dart' show FixtureCommands;

class SkillFixture extends FixtureCommands implements LocalSkillCommands {
  bool enabled = false;
  int activation = 0;
  final selectedPins = <String>[];
  @override
  Future<List<LocalSkillChoice>> listSkills() async => [
    LocalSkillChoice(
      skillId: 'orange.text-summary',
      version: '1.0.0',
      digest: '1' * 64,
      scenario: 'AU-02',
      displayName: '文本摘要',
      instruction: 'Summarize the source.',
      tools: const [],
      enabled: enabled,
      revision: activation.toString(),
    ),
  ];
  @override
  Future<String> setSkillEnabled(LocalSkillChoice choice, bool enable) async {
    if (choice.revision != activation.toString()) throw StateError('stale');
    enabled = enable;
    activation++;
    return activation.toString();
  }

  @override
  Future<AgentRunView> startSkill(
    String workspace,
    String requestId,
    String prompt,
    LocalSkillChoice choice,
  ) async {
    id = requestId;
    selectedPins.add('${choice.digest}/${choice.revision}');
    return state('completed');
  }
}

void main() {
  test(
    'disabled or superseded selections never become a generic start',
    () async {
      final api = SkillFixture();
      final agent = AgentController(
        api,
        serviceDirectory: () async => '/private/fixture-service',
      );
      addTearDown(agent.dispose);
      await agent.connect();
      await agent.refreshSkills();
      final disabled = agent.skills.single;
      await agent.start('work', 'test input', skill: disabled);
      expect(api.selectedPins, isEmpty);
      expect(api.starts, isEmpty);
      await agent.toggleSkill(disabled);
      final first = agent.skills.single;
      await agent.toggleSkill(first);
      await agent.toggleSkill(agent.skills.single);
      await agent.start('work', 'test input', skill: first);
      expect(api.selectedPins, isEmpty);
      expect(api.starts, isEmpty);
      final current = agent.skills.single;
      await agent.start(
        'work',
        'test input',
        skill: current,
        allowQuestions: true,
      );
      expect(api.selectedPins, ['${current.digest}/3']);
      expect(api.starts, isEmpty);
    },
  );
}
