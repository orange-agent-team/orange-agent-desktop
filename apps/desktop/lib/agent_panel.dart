import 'dart:convert';

import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'local_skill_picker.dart';
import 'src/rust/api/memory.dart' as mem;
import 'question_panel.dart';
import 'src/rust/api/host.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({
    super.key,
    required this.controller,
    required this.workspaces,
    this.memory,
    this.memoryWrite = false,
    this.creations = const [],
    this.editings = const [],
  });
  final mem.MemorySelection? memory;
  final bool memoryWrite;
  final AgentController controller;
  final List<WorkspaceView> workspaces;
  final List<CreationAccessView> creations;
  final List<EditingAccessView> editings;
  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> with WidgetsBindingObserver {
  final prompt = TextEditingController();
  String? selected;
  String? selectedSkillDigest;
  bool allowMemory = false, writeMemory = false;
  bool allowQuestions = false, allowCreation = false, allowEditing = false;
  AgentController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.refreshSkills();
    });
  }

  @override
  void didUpdateWidget(covariant AgentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller)) {
      selectedSkillDigest = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.refreshSkills();
      });
    }
    if (oldWidget.memory?.sessionToken != widget.memory?.sessionToken) {
      allowMemory = false;
      writeMemory = false;
    }
    String editingKey(List<EditingAccessView> rows) => rows
        .map((e) => '${e.consentId}:${e.permissionVersion}:${e.sessionToken}')
        .join('|');
    if (editingKey(oldWidget.editings) != editingKey(widget.editings)) {
      allowEditing = false;
      controller.editPreview = null;
      for (final old in oldWidget.editings) {
        if (!widget.editings.any(
          (current) =>
              current.consentId == old.consentId &&
              current.permissionVersion == old.permissionVersion &&
              current.sessionToken == old.sessionToken,
        )) {
          controller.editingStopping(old.consentId);
        }
      }
    }
    String key(List<CreationAccessView> rows) => rows
        .map((c) => '${c.consentId}:${c.permissionVersion}:${c.sessionToken}')
        .join('|');
    if (key(oldWidget.creations) != key(widget.creations)) {
      allowCreation = false;
    }
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
      final creation = widget.creations
          .where(
            (c) =>
                c.workspaceId == selectedId &&
                c.permissionActive &&
                c.sessionToken != null,
          )
          .firstOrNull;
      final editing = widget.editings
          .where(
            (e) =>
                e.workspaceId == selectedId &&
                e.permissionActive &&
                e.sessionToken != null,
          )
          .firstOrNull;
      final run = controller.view;
      final busy = controller.busy || controller.cancelling;
      final chosenSkill = controller.skills
          .where((v) => v.digest == selectedSkillDigest)
          .firstOrNull;
      final templateSelected = selectedSkillDigest != null;
      final patchSelected = chosenSkill?.skillId == 'orange.reviewed-patch';
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
                  labelText: '本次会话的工作区',
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
                    : (value) => setState(() {
                        selected = value;
                        allowCreation = false;
                        allowEditing = false;
                      }),
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
              if (controller.supportsSkills)
                LocalSkillPicker(
                  controller: controller,
                  selectedDigest: selectedSkillDigest,
                  locked:
                      busy || controller.active || controller.startUnconfirmed,
                  onChanged: (digest) => setState(() {
                    selectedSkillDigest = digest;
                    allowEditing = false;
                  }),
                ),
              if (!templateSelected) ...[
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
                CheckboxListTile(
                  title: const Text('允许提出新建文件请求'),
                  subtitle: Text(
                    creation == null
                        ? '请先在创建权限区域选择同一文件夹；每个文件仍需单独批准。'
                        : '只允许创建新文件，不覆盖现有内容。每次创建前会显示完整路径和内容。',
                  ),
                  value: allowCreation && creation != null,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  onChanged:
                      creation == null ||
                          busy ||
                          controller.active ||
                          controller.startUnconfirmed
                      ? null
                      : (value) =>
                            setState(() => allowCreation = value ?? false),
                ),
              ],
              if (!templateSelected || patchSelected)
                CheckboxListTile(
                  title: const Text('允许提出修改现有文件请求'),
                  subtitle: Text(
                    editing == null
                        ? '请先单独选择同一文件夹的编辑权限；每次修改仍须批准。'
                        : '每次先读取实际差异，不会因打开此选项自动执行。',
                  ),
                  value: allowEditing && editing != null,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  onChanged:
                      editing == null ||
                          busy ||
                          controller.active ||
                          controller.startUnconfirmed
                      ? null
                      : (value) =>
                            setState(() => allowEditing = value ?? false),
                ),
              if (!templateSelected && widget.memory != null) ...[
                CheckboxListTile(
                  value: allowMemory,
                  title: Text('允许本次任务读取记忆空间 ${widget.memory!.scopeId}'),
                  onChanged: busy || controller.active
                      ? null
                      : (v) => setState(() {
                          allowMemory = v ?? false;
                          writeMemory = false;
                        }),
                ),
                if (allowMemory && widget.memoryWrite)
                  CheckboxListTile(
                    value: writeMemory,
                    title: const Text('允许提出记忆修改，逐次确认'),
                    onChanged: busy || controller.active
                        ? null
                        : (v) => setState(() => writeMemory = v ?? false),
                  ),
              ],
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
                            (templateSelected &&
                                (controller.skillBusy ||
                                    chosenSkill?.enabled != true ||
                                    (chosenSkill?.requiredModelProfile !=
                                            null &&
                                        controller.model?.qualifiedSkills !=
                                            true) ||
                                    (patchSelected &&
                                        (!allowEditing || editing == null)))) ||
                            controller.model == null ||
                            selectedId == null ||
                            prompt.text.trim().isEmpty
                        ? null
                        : () => controller.start(
                            selectedId,
                            prompt.text,
                            skill: chosenSkill,
                            allowQuestions: allowQuestions,
                            memory: allowMemory && widget.memory != null
                                ? mem.TaskMemorySelection(
                                    scopes: [
                                      mem.TaskMemoryScope(
                                        scopeId: widget.memory!.scopeId,
                                        sessionToken:
                                            widget.memory!.sessionToken,
                                        write:
                                            writeMemory && widget.memoryWrite,
                                      ),
                                    ],
                                    sources: widget.memory!.sources,
                                    creation: allowCreation && creation != null
                                        ? RunPermissionSelection(
                                            consentId: creation.consentId,
                                            permissionVersion:
                                                creation.permissionVersion,
                                          )
                                        : null,
                                    editing: allowEditing && editing != null
                                        ? RunPermissionSelection(
                                            consentId: editing.consentId,
                                            permissionVersion:
                                                editing.permissionVersion,
                                          )
                                        : null,
                                  )
                                : null,
                            creation: allowCreation ? creation : null,
                            editing: allowEditing ? editing : null,
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
              if (controller.view == null &&
                  controller.memoryRequirements.isNotEmpty) ...[
                Text(
                  '恢复任务所需的记忆空间：${controller.memoryRequirements.map((r) => "${r.scopeId}（${r.write ? '读写' : '只读'}，版本 ${r.revision}）").join('、')}',
                ),
                OutlinedButton(
                  onPressed:
                      busy ||
                          widget.memory == null ||
                          controller.memoryRequirements.length != 1 ||
                          controller.memoryRequirements.single.scopeId !=
                              widget.memory!.scopeId ||
                          (controller.memoryRequirements.single.write &&
                              !widget.memoryWrite)
                      ? null
                      : () => controller.restoreMemory(widget.memory!),
                  child: const Text('使用已选空间恢复任务访问'),
                ),
              ],
              if (controller.usesMemory &&
                  controller.runId != null &&
                  (controller.view == null ||
                      controller.view?.phase == 'recovery_required' ||
                      controller.view?.phase == 'tools_pending')) ...[
                TextButton(
                  onPressed: busy ? null : controller.inspectUncertainWrites,
                  child: const Text('核对未确认的记忆写入'),
                ),
                for (final item in controller.uncertainWrites)
                  ListTile(
                    title: Text(item.outcome.entryId),
                    subtitle: Text(
                      item.outcome.state == 'approved'
                          ? '已提交到版本 ${item.outcome.resultVersion}'
                          : '草稿回执显示尚未提交',
                    ),
                    trailing: Wrap(
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => controller.resolveMemory(item, false),
                          child: const Text('按回执结束'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => controller.resolveMemory(item, true),
                          child: const Text('按回执恢复'),
                        ),
                      ],
                    ),
                  ),
              ],
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
                if (run.phase == 'recovery_required' &&
                    controller.supportsModelObservation) ...[
                  TextButton(
                    onPressed: controller.inspectModelFailure,
                    child: const Text('核对模型派发记录'),
                  ),
                  if (controller.observedFailure case final obs?) ...[
                    Text(switch (obs.reason) {
                      'call_time_limit' => '模型调用达到运行时的单次等待上限。',
                      'gateway_failed' => '模型适配器报告失败，派发结果仍需核对。',
                      'run_deadline' => '整个会话的截止时间已到。',
                      'host_reopened' => '宿主重启时发现一条尚未确认的模型派发。',
                      _ => '正在核对模型派发。',
                    }),
                    SelectableText('调用编号 ${obs.invocationId}'),
                    if (obs.elapsedMs != null && obs.waitLimitMs != null)
                      Text(
                        '实际等待 ${obs.elapsedMs} 毫秒 · 当时上限 ${obs.waitLimitMs} 毫秒',
                      ),
                  ],
                  if (controller.observationMessage != null)
                    Text(controller.observationMessage!),
                ],
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
                          if (pending[i].toolName == 'write_file')
                            const Text('将创建下面的新文件。内容来自模型，请完整核对；现有文件不会被替换。'),
                          if (pending[i].toolName == 'memory_write') ...[
                            OutlinedButton(
                              onPressed: busy || i != 0
                                  ? null
                                  : controller.previewMemoryWrite,
                              child: const Text('核对记忆修改和来源'),
                            ),
                            if (i == 0 && controller.memoryReviewMatches) ...[
                              _MemoryChange(review: controller.memoryReview!),
                            ],
                          ] else if (pending[i].toolName == 'apply_patch') ...[
                            const Text('修改现有文件。先获取并核对实际差异；批准只适用于这一次内容和版本。'),
                            OutlinedButton(
                              onPressed: busy || i != 0
                                  ? null
                                  : controller.previewFirstEdit,
                              child: const Text('读取实际差异'),
                            ),
                            if (i == 0 && controller.editPreviewMatches) ...[
                              SelectableText(controller.editPreview!.path),
                              SelectableText(controller.editPreview!.diff),
                              SelectableText(
                                '原摘要：${controller.editPreview!.originalSha256}\n新摘要：${controller.editPreview!.resultSha256}',
                              ),
                            ],
                          ] else if (pending[i].toolName == 'write_file')
                            CreationPreview(arguments: pending[i].argumentsJson)
                          else
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
                if (run.finalText != null &&
                    (run.sourceReferences?.isNotEmpty ?? false)) ...[
                  Text('已核对的来源', style: Theme.of(context).textTheme.titleSmall),
                  for (final ref in run.sourceReferences!)
                    SelectableText(
                      '${ref.path} · 字节 [${ref.startByte}, ${ref.endByte}) · SHA-256 ${ref.sha256}',
                    ),
                ],
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

class CreationPreview extends StatelessWidget {
  const CreationPreview({super.key, required this.arguments});
  final String arguments;
  @override
  Widget build(BuildContext context) {
    final preview = parseCreationPreview(arguments);
    if (preview == null) return const Text('无法完整显示文件提案，已禁止批准。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('新文件路径'),
        SelectableText(preview.path),
        const SizedBox(height: 8),
        const Text('完整文件内容'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SelectableText(
              preview.content.isEmpty ? '（空文件）' : preview.content,
            ),
          ),
        ),
      ],
    );
  }
}

class _MemoryChange extends StatelessWidget {
  const _MemoryChange({required this.review});
  final mem.TaskMemoryReview review;
  @override
  Widget build(BuildContext context) {
    final draft = jsonDecode(review.reviewJson) as Map<String, dynamic>;
    final sources = jsonDecode(review.sourcesJson) as List<dynamic>;
    final payload = draft['payload'] as Map<String, dynamic>?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${draft["scope_id"]} · ${draft["entry_id"]}'),
        Text(
          draft['expected_version'] == null
              ? '新增记忆'
              : '基于版本 ${draft["expected_version"]}',
        ),
        if (draft['mutation'] == 'delete') const Text('确认后删除这条记忆。'),
        if (payload != null) ...[
          SelectableText(payload['title'] as String),
          SelectableText(payload['content'] as String),
          Text(payload['enabled'] == true ? '保存后启用' : '保存后禁用'),
        ],
        if (sources.isNotEmpty)
          ExpansionTile(
            title: Text('查看 ${sources.length} 个来源'),
            children: [
              for (final source in sources)
                ListTile(
                  title: SelectableText(
                    source['kind'] == 'memory'
                        ? '${source["scope"]} · ${source["entry"]} · 版本 ${source["version"]}'
                        : '工作区操作 ${source["operation"]}',
                  ),
                  subtitle: source['kind'] == 'workspace'
                      ? SelectableText(source['result_digest'] as String)
                      : null,
                ),
            ],
          ),
      ],
    );
  }
}
