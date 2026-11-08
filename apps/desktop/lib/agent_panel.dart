import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'question_panel.dart';
import 'src/rust/api/host.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({
    super.key,
    required this.controller,
    required this.workspaces,
  });
  final AgentController controller;
  final List<WorkspaceView> workspaces;
  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> with WidgetsBindingObserver {
  final prompt = TextEditingController();
  String? selected;
  bool allowQuestions = false;
  AgentController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    prompt.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      controller.hideContent();
    } else if (state == AppLifecycleState.resumed && controller.runId != null) {
      controller.load(controller.runId!);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final available = widget.workspaces
          .where((w) => w.permissionActive && w.sessionAccess)
          .toList();
      final selectedId = available.any((w) => w.workspaceId == selected)
          ? selected
          : null;
      final run = controller.view;
      final busy = controller.busy || controller.cancelling;
      final pending = run?.pending ?? const <ToolApprovalView>[];
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本地会话', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    controller.model == null
                        ? '模型服务未连接'
                        : controller.model!.displayName,
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || controller.connecting
                        ? null
                        : controller.connect,
                    icon: const Icon(Icons.link),
                    label: Text(controller.connecting ? '正在连接…' : '连接本地模型'),
                  ),
                ],
              ),
              if (controller.model != null) const Text('本地开发模型；尚未取得生产模型认证。'),
              if (controller.model == null)
                const Text('连接已在本机安装并启动的模型服务。模型不可用时不会开始执行。'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(
                  '${selectedId ?? "none"}:${available.map((w) => w.sessionToken).join(",")}',
                ),
                initialValue: selectedId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '本次会话的只读工作区',
                  border: OutlineInputBorder(),
                ),
                items: available
                    .map(
                      (w) => DropdownMenuItem(
                        value: w.workspaceId,
                        child: Text(
                          w.displayPath,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: busy || controller.active
                    ? null
                    : (value) => setState(() => selected = value),
              ),
              if (available.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('请先选择文件夹，恢复本次只读访问。'),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: prompt,
                onChanged: (_) => setState(() {}),
                minLines: 2,
                maxLines: 6,
                readOnly:
                    busy || controller.active || controller.startUnconfirmed,
                decoration: const InputDecoration(
                  labelText: '希望完成的任务',
                  hintText: '例如：读取工作区中的 README 并总结内容',
                  border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                title: const Text('允许任务询问补充信息'),
                value: allowQuestions,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                onChanged:
                    busy || controller.active || controller.startUnconfirmed
                    ? null
                    : (value) =>
                          setState(() => allowQuestions = value ?? false),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed:
                        busy ||
                            controller.active ||
                            controller.startUnconfirmed ||
                            controller.model == null ||
                            selectedId == null ||
                            prompt.text.trim().isEmpty
                        ? null
                        : () => controller.start(
                            selectedId,
                            prompt.text,
                            allowQuestions: allowQuestions,
                          ),
                    child: const Text('开始会话'),
                  ),
                  if (controller.startUnconfirmed)
                    OutlinedButton(
                      onPressed: busy ? null : controller.retryStart,
                      child: const Text('核对创建结果'),
                    ),
                  if (controller.runId != null)
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => controller.load(controller.runId!),
                      child: const Text('核对状态'),
                    ),
                  if (controller.canAdvance)
                    OutlinedButton(
                      onPressed:
                          busy ||
                              controller.model == null ||
                              !controller.matchingModel
                          ? null
                          : controller.continueRun,
                      child: const Text('继续执行'),
                    ),
                  if (controller.runId != null)
                    TextButton(
                      onPressed: controller.cancelling
                          ? null
                          : controller.cancel,
                      child: Text(controller.cancelling ? '正在停止…' : '停止会话'),
                    ),
                ],
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (controller.notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(controller.notice!),
                ),
              if (run != null) ...[
                const Divider(height: 28),
                Text('${phaseLabel(run.phase)} · ${run.steps} 步'),
                if (!controller.matchingModel)
                  const Text('继续执行需要连接此会话使用的原模型版本。'),
                if (run.failure != null) const Text('本次执行已停止；请核对状态后处理恢复记录。'),
                if (run.phase == 'awaiting_user' && run.userQuestion != null)
                  QuestionPanel(
                    key: ValueKey(
                      '${run.runId}:${run.userQuestion!.questionId}:${run.userQuestion!.argumentDigest}',
                    ),
                    question: run.userQuestion!,
                    busy: busy,
                    onSubmit: controller.answerQuestion,
                  ),
                for (var i = 0; i < pending.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i == 0 ? '需要你的批准' : '后续待批准请求',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(toolDisplayName(pending[i].toolName)),
                          SelectableText(pending[i].argumentsJson),
                          ExpansionTile(
                            title: const Text('操作标识与内容校验'),
                            children: [
                              SelectableText(pending[i].operationId),
                              SelectableText(pending[i].argumentDigest),
                            ],
                          ),
                          if (i == 0)
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton(
                                  onPressed:
                                      busy ||
                                          controller.model == null ||
                                          !controller.matchingModel ||
                                          !controller.supportedPreview
                                      ? null
                                      : controller.approveFirst,
                                  child: Text(controller.approvalLabel),
                                ),
                                TextButton(
                                  onPressed: controller.cancelling
                                      ? null
                                      : controller.cancel,
                                  child: const Text('拒绝并停止'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                if (pending.isNotEmpty && !controller.supportedPreview)
                  const Text('当前版本无法批准此工具权限，请停止会话。'),
                if (run.finalText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(run.finalText!),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

String phaseLabel(String phase) => switch (phase) {
  'ready' => '等待继续',
  'model_pending' => '模型处理中',
  'tools_pending' => '工具请求待处理',
  'awaiting_user' => '等待你的回答',
  'completed' => '已完成',
  'cancelled' => '已停止',
  'limited' => '已达到限制',
  'failed' => '执行失败',
  'recovery_required' => '需要核对未确认的执行',
  _ => '未知状态，已停止推进',
};
