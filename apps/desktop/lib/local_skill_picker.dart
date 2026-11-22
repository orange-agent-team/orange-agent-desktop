import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'src/rust/api/host.dart';

class LocalSkillPicker extends StatelessWidget {
  const LocalSkillPicker({
    super.key,
    required this.controller,
    required this.selectedDigest,
    required this.locked,
    required this.onChanged,
  });
  final AgentController controller;
  final String? selectedDigest;
  final bool locked;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final choices = controller.skills;
    final LocalSkillChoice? selected = choices
        .where((v) => v.digest == selectedDigest)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: '运行模板'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const ValueKey('local-skill-choice'),
              isExpanded: true,
              value: selectedDigest ?? 'general',
              items: [
                const DropdownMenuItem(value: 'general', child: Text('通用会话')),
                if (selectedDigest != null && selected == null)
                  DropdownMenuItem(
                    value: selectedDigest,
                    enabled: false,
                    child: const Text('所选模板版本不可用'),
                  ),
                for (final entry in choices)
                  DropdownMenuItem(
                    value: entry.digest,
                    child: Text('${entry.displayName} · ${entry.version}'),
                  ),
              ],
              onChanged: locked || controller.skillBusy
                  ? null
                  : (value) => onChanged(value == 'general' ? null : value),
            ),
          ),
        ),
        if (controller.skillError != null) Text(controller.skillError!),
        if (controller.skillError != null)
          TextButton(
            onPressed: controller.skillBusy ? null : controller.refreshSkills,
            child: const Text('重读模板目录'),
          ),
        if (selected != null) ...[
          Text(
            selected.tools.isEmpty
                ? '此模板仅使用任务文本。'
                : '可申请的只读工具：${selected.tools.join('、')}。读取仍需工作区授权。',
          ),
          ExpansionTile(
            title: const Text('模板指令与版本摘要'),
            children: [
              SelectableText(selected.instruction),
              SelectableText(selected.digest),
            ],
          ),
          TextButton(
            onPressed: locked || controller.skillBusy
                ? null
                : () => controller.toggleSkill(selected),
            child: Text(selected.enabled ? '停用此版本' : '启用此版本'),
          ),
        ],
      ],
    );
  }
}
