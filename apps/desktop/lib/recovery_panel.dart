import 'dart:convert';

import 'package:flutter/material.dart';

import 'recovery_controller.dart';
import 'src/rust/api/host.dart';

/// Displays actual inspection observations. It never equates matching bytes
/// with a committed tool receipt and has no automatic recovery/write action.
class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({
    super.key,
    required this.controller,
    required this.supported,
  });
  final RecoveryController controller;
  final bool supported;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel> {
  final expansion = ExpansibleController();
  int lastNavigation = -1;
  RecoveryController get controller => widget.controller;
  bool get supported => widget.supported;
  @override
  void initState() {
    super.initState();
    lastNavigation = controller.navigationRevision;
    controller.addListener(openSelected);
  }

  void openSelected() {
    if (lastNavigation == controller.navigationRevision) return;
    lastNavigation = controller.navigationRevision;
    if (controller.selected == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) expansion.expand();
    });
  }

  @override
  void didUpdateWidget(covariant RecoveryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(openSelected);
      controller.addListener(openSelected);
      lastNavigation = -1;
      openSelected();
    }
  }

  @override
  void dispose() {
    controller.removeListener(openSelected);
    expansion.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() work) async {
    try {
      await work();
    } catch (failure, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: failure,
          stack: stack,
          library: 'recovery inspection action',
        ),
      );
    }
  }

  String _file(RecoveryFileStatusView value) => switch (value.kind) {
    'missing' => '不存在',
    'refused' => '文件类型或大小不符合检查要求',
    'regular' when value.matchesResultContent => '内容与待发布版本一致',
    'regular' when value.matchesOriginalContent => '内容与原始版本一致',
    'regular' => '文件存在，内容已变化',
    _ => '无法识别当前状态',
  };
  String _choice(String? value) => switch (value) {
    'keep_current_target' => '保留当前文件',
    'restore_original_to_missing_target' => '把保留原件放回空缺位置',
    'publish_staged_to_missing_target' => '把待发布版本放到空缺位置',
    _ => '未识别的处理决定',
  };
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller, view = controller.snapshot;
      return Card(
        child: ExpansionTile(
          controller: expansion,
          initiallyExpanded: c.selected != null,
          title: const Text('中断编辑检查'),
          subtitle: Text(c.error ?? (c.busy ? '正在处理检查请求…' : '单独授权读取当前文件状态')),
          onExpansionChanged: (open) {
            if (open && supported && !c.loaded && c.selected == null) {
              c.refresh();
            }
          },
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    supported
                        ? '先选择运行和操作，再授权读取目录。检查不会修改文件或继续旧任务。'
                        : '此平台尚未提供恢复检查。',
                  ),
                  if (supported) ...[
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: c.busy ? null : () => c.refresh(),
                          child: const Text('刷新检查记录'),
                        ),
                        OutlinedButton(
                          onPressed: c.busy || c.nextCursor == null
                              ? null
                              : () => c.refresh(older: true),
                          child: const Text('加载更早记录'),
                        ),
                        OutlinedButton(
                          onPressed: () => _action(c.stop),
                          child: const Text('结束恢复检查'),
                        ),
                      ],
                    ),
                    if (c.busy) const LinearProgressIndicator(),
                    if (c.error != null)
                      Text(
                        c.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (c.loaded && c.runs.isEmpty)
                      const Text('本页没有待核对或已停止的运行。'),
                    for (final run in c.runs)
                      ListTile(
                        title: Text(run.runId),
                        subtitle: Text(
                          run.phase == 'recovery_required'
                              ? '结果待核对'
                              : '已停止，可查询未确认的编辑',
                        ),
                        trailing: TextButton(
                          onPressed: c.busy ? null : () => c.selectRun(run),
                          child: const Text('选择记录'),
                        ),
                      ),
                    if (c.selected != null) ...[
                      Text('已选运行：${c.selected!.runId}'),
                      if (c.workspacePaths[c.selected!.workspaceId] != null)
                        SelectableText(
                          '记录的工作区：${jsonEncode(c.workspacePaths[c.selected!.workspaceId])}',
                        ),
                      if (!c.busy && c.operations.isEmpty)
                        const Text('该运行没有尚未解决的文件编辑记录；其他类型的异常需另行核对。'),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (
                            var index = 0;
                            index < c.operations.length;
                            index++
                          )
                            ChoiceChip(
                              label: Text('操作 ${index + 1}'),
                              selected: c.operation == c.operations[index],
                              onSelected: c.busy
                                  ? null
                                  : (_) => _action(
                                      () => c.selectOperation(
                                        c.operations[index],
                                      ),
                                    ),
                            ),
                        ],
                      ),
                      FilledButton(
                        onPressed:
                            c.busy ||
                                c.operation == null ||
                                c.selected?.workspaceId == null ||
                                c.outcome?.recoveryId != null
                            ? null
                            : c.chooseAndInspect,
                        child: const Text('选择目录进行恢复检查'),
                      ),
                    ],
                    if (c.access != null)
                      SelectableText(
                        '检查目录：${jsonEncode(c.access!.displayDirectory)}',
                      ),
                    if (c.access != null)
                      OutlinedButton(
                        onPressed: c.busy ? null : c.inspectCurrent,
                        child: const Text('刷新文件观察'),
                      ),
                    if (c.notice != null) Text(c.notice!),
                    if (c.outcome?.recoveryId != null)
                      Text('已记录决定：${_choice(c.outcome!.choice)}'),
                    if (view != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        c.outcome?.recoveryId == null
                            ? '原修改记录仍待核对'
                            : '已记录处理后的文件观察',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Text('以下是本次检查时观察到的文件状态。'),
                      SelectableText('文件：${jsonEncode(view.path)}'),
                      Text('当前文件：${_file(view.target)}'),
                      Text('待发布文件：${_file(view.staged)}'),
                      Text('保留原件：${_file(view.original)}'),
                      const Text('内容匹配不代表原操作已经确认完成。'),
                      if (c.writer != null &&
                          c.outcome?.recoveryId == null) ...[
                        OutlinedButton(
                          onPressed: c.busy ? null : c.chooseWrite,
                          child: const Text('单独授权处理这次改动'),
                        ),
                        if (c.writeAccess != null) ...[
                          const Text('写入目录已单独授权。选择处理方式后，仍需核对实际决定并批准。'),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (view.target.kind == 'regular')
                                OutlinedButton(
                                  onPressed: c.busy
                                      ? null
                                      : () => c.prepareDecision(
                                          'keep_current_target',
                                        ),
                                  child: const Text('核对保留当前文件'),
                                ),
                              if (view.target.kind == 'missing' &&
                                  view.original.kind == 'regular' &&
                                  view.original.reviewedOriginalInode &&
                                  view.original.matchesOriginalContent)
                                OutlinedButton(
                                  onPressed: c.busy
                                      ? null
                                      : () => c.prepareDecision(
                                          'restore_original_to_missing_target',
                                        ),
                                  child: const Text('核对放回原件'),
                                ),
                              if (view.target.kind == 'missing' &&
                                  view.staged.kind == 'regular' &&
                                  view.staged.matchesResultContent)
                                OutlinedButton(
                                  onPressed: c.busy
                                      ? null
                                      : () => c.prepareDecision(
                                          'publish_staged_to_missing_target',
                                        ),
                                  child: const Text('核对发布待写入版本'),
                                ),
                            ],
                          ),
                        ],
                        if (c.decision != null) ...[
                          Text(
                            '待批准决定：${_choice(c.decision!.choice)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SelectableText(
                            '对应文件：${jsonEncode(c.decision!.inspection.path)}',
                          ),
                          const Text('其他保留版本不会因此删除，旧任务不会自动继续。'),
                          FilledButton(
                            onPressed: c.busy ? null : c.approveDecision,
                            child: const Text('批准这个处理决定'),
                          ),
                        ],
                      ],
                      ExpansionTile(
                        title: const Text('查看核对摘要'),
                        children: [
                          for (final item in [
                            (label: '当前文件', value: view.target),
                            (label: '待发布文件', value: view.staged),
                            (label: '保留原件', value: view.original),
                          ])
                            if (item.value.sha256 != null)
                              ListTile(
                                title: Text(
                                  '${item.label} · ${item.value.bytes} 字节',
                                ),
                                subtitle: SelectableText(
                                  'SHA-256: ${item.value.sha256}\n权限属性摘要: ${item.value.securitySha256}',
                                ),
                              ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
