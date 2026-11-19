import 'dart:async';

import 'package:flutter/material.dart';

import 'memory_controller.dart';
import 'src/rust/api/memory.dart' as api;
import 'src/rust/api/host.dart' show WorkspaceView;

class MemoryPanel extends StatefulWidget {
  const MemoryPanel({
    super.key,
    required this.controller,
    required this.workspaces,
  });
  final MemoryController controller;
  final List<WorkspaceView> workspaces;
  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  final title = TextEditingController(),
      content = TextEditingController(),
      scopeId = TextEditingController(),
      principal = TextEditingController();
  bool enabled = true, newEntry = false, shared = false;
  String memberAccess = 'read';
  int visibility = -1;
  String? displayedEntry, displayedScope;
  MemoryController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    changed();
  }

  @override
  void didUpdateWidget(covariant MemoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(changed);
      c.addListener(changed);
      visibility = -1;
      displayedScope = null;
      changed();
    }
  }

  void changed() {
    if (displayedScope != c.selectedScope) {
      displayedScope = c.selectedScope;
      principal.clear();
      memberAccess = 'read';
    }
    if (visibility != c.visibilityEpoch) {
      visibility = c.visibilityEpoch;
      title.clear();
      content.clear();
      enabled = true;
      newEntry = false;
      displayedEntry = null;
    }
    final value = c.entry;
    final key = value == null ? null : '${value.entryId}:${value.version}';
    if (value != null && displayedEntry != key) {
      displayedEntry = key;
      title.text = value.title;
      content.text = value.content;
      enabled = value.enabled;
      newEntry = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(changed);
    title.dispose();
    content.dispose();
    scopeId.dispose();
    principal.dispose();
    super.dispose();
  }

  Future<void> createScope() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('新建记忆空间'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('memory-scope-id'),
                controller: scopeId,
                decoration: const InputDecoration(
                  labelText: '空间标识',
                  helperText: '使用字母、数字或 _ . : -',
                ),
              ),
              CheckboxListTile(
                value: shared,
                onChanged: (v) => update(() => shared = v ?? false),
                title: const Text('允许明确添加共享成员'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (choice == true && mounted) {
      await c.createScope(scopeId.text.trim(), shared);
    }
  }

  Widget sources() {
    final available = widget.workspaces
        .where((v) => v.permissionActive && v.sessionAccess)
        .toList();
    return ExpansionTile(
      title: const Text('验证原始来源'),
      subtitle: const Text('只使用你明确选中的已授权来源'),
      children: [
        if (available.isEmpty)
          const ListTile(title: Text('暂无已打开的工作区。可先在工作区面板恢复访问。')),
        for (final workspace in available)
          CheckboxListTile(
            value: c.sourceWorkspaces.contains(workspace.workspaceId),
            title: Text(workspace.displayPath),
            onChanged:
                c.busy && !c.sourceWorkspaces.contains(workspace.workspaceId)
                ? null
                : (v) => unawaited(
                    c.setSourceWorkspace(workspace.workspaceId, v ?? false),
                  ),
          ),
        for (final scope in c.scopes.where(
          (v) => v.scopeId != c.selectedScope && v.enabled,
        ))
          CheckboxListTile(
            value: c.sourceAccess.containsKey(scope.scopeId),
            title: Text('记忆空间：${scope.scopeId}'),
            onChanged: c.busy && !c.sourceAccess.containsKey(scope.scopeId)
                ? null
                : (v) => unawaited(c.setSourceMemory(scope, v ?? false)),
          ),
      ],
    );
  }

  Widget members() => ExpansionTile(
    title: const Text('共享成员权限'),
    children: [
      TextButton(
        onPressed: c.busy ? null : () => unawaited(c.loadMembers()),
        child: const Text('读取成员'),
      ),
      for (final member in c.memberRows)
        ListTile(
          title: Text(member.principal),
          subtitle: Text(
            member.access == 'read'
                ? '只读'
                : member.access == 'write'
                ? '读写'
                : '已撤回',
          ),
          trailing: member.principal == c.scope?.owner
              ? const Text('所有者')
              : DropdownButton<String>(
                  value: member.access,
                  items: const [
                    DropdownMenuItem(value: 'read', child: Text('只读')),
                    DropdownMenuItem(value: 'write', child: Text('读写')),
                    DropdownMenuItem(value: 'revoked', child: Text('撤回')),
                  ],
                  onChanged: c.busy
                      ? null
                      : (v) {
                          if (v != null) {
                            unawaited(c.setMember(member.principal, v));
                          }
                        },
                ),
        ),
      if (c.memberCursor != null)
        TextButton(
          onPressed: c.busy ? null : () => unawaited(c.loadMembers(more: true)),
          child: const Text('更多成员'),
        ),
      TextField(
        key: const Key('memory-principal'),
        controller: principal,
        enabled: !c.busy,
        decoration: const InputDecoration(labelText: '成员标识'),
      ),
      Row(
        children: [
          DropdownButton<String>(
            key: const Key('memory-member-access'),
            value: memberAccess,
            items: const [
              DropdownMenuItem(value: 'read', child: Text('只读')),
              DropdownMenuItem(value: 'write', child: Text('读写')),
            ],
            onChanged: c.busy
                ? null
                : (v) => setState(() => memberAccess = v ?? 'read'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: c.busy
                ? null
                : () => unawaited(
                    c.setMember(principal.text.trim(), memberAccess),
                  ),
            child: const Text('设置成员权限'),
          ),
        ],
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final scope = c.scope;
    final preview = c.preview;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('本地记忆', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                TextButton(
                  onPressed: c.busy ? null : createScope,
                  child: const Text('新建空间'),
                ),
                IconButton(
                  tooltip: '刷新空间并关闭当前访问',
                  onPressed: c.busy ? null : () => unawaited(c.refresh()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(c.selectedScope),
              initialValue: c.selectedScope,
              decoration: const InputDecoration(labelText: '记忆空间'),
              items: c.scopes
                  .map(
                    (v) => DropdownMenuItem(
                      value: v.scopeId,
                      child: Text(
                        '${v.scopeId}${v.shared ? ' · 共享' : ''}${v.enabled ? '' : ' · 已停用'}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: c.busy ? null : (v) => unawaited(c.chooseScope(v)),
            ),
            if (c.scopeCursor != null)
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => unawaited(c.refresh(more: true)),
                child: const Text('更多空间'),
              ),
            if (scope != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: c.busy || !scope.enabled
                        ? null
                        : () => unawaited(c.open(write: false)),
                    child: const Text('打开只读访问'),
                  ),
                  OutlinedButton(
                    onPressed:
                        c.busy || !scope.enabled || scope.access != 'write'
                        ? null
                        : () => unawaited(c.open(write: true)),
                    child: const Text('打开编辑访问'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(c.closeAccess()),
                    child: const Text('关闭访问'),
                  ),
                  if (scope.canAdminister)
                    TextButton(
                      onPressed: c.busy
                          ? null
                          : () => unawaited(c.setEnabled(!scope.enabled)),
                      child: Text(scope.enabled ? '停用空间' : '启用空间'),
                    ),
                ],
              ),
              if (!scope.enabled) const Text('空间已停用。这里只显示管理信息，正文访问仍关闭。'),
            ],
            if (scope != null && scope.shared && scope.canAdminister) members(),
            if (c.busy) const LinearProgressIndicator(),
            if (c.error != null)
              Text(
                c.error!,
                key: const Key('memory-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (c.notice != null)
              Text(c.notice!, key: const Key('memory-notice')),
            if (c.access != null) ...[
              Text(c.canWrite ? '当前访问：读取与明确批准的编辑' : '当前访问：只读'),
              sources(),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: c.busy ? null : () => unawaited(c.loadEntries()),
                    child: const Text('读取列表'),
                  ),
                  if (c.canWrite)
                    FilledButton.tonal(
                      onPressed: c.busy
                          ? null
                          : () {
                              c.beginNew();
                              setState(() => newEntry = true);
                            },
                      child: const Text('新增记忆'),
                    ),
                ],
              ),
              CheckboxListTile(
                value: c.includeDisabled,
                onChanged: c.busy
                    ? null
                    : (v) => unawaited(c.showDisabled(v ?? false)),
                title: const Text('同时显示已禁用的条目'),
              ),
              if (c.omitted) const Text('部分条目的原始来源尚未授权或已经变化，内容未显示。'),
              for (final row in c.entries)
                ListTile(
                  key: ValueKey('memory-entry-${row.entryId}'),
                  title: Text(row.title),
                  subtitle: Text(
                    '${row.origin == 'user_declaration' ? '用户声明' : '模型推断'} · 版本 ${row.version}${row.enabled ? '' : ' · 已禁用'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: c.busy ? null : () => unawaited(c.readEntry(row)),
                ),
              if (c.entryCursor != null)
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () => unawaited(c.loadEntries(more: true)),
                  child: Text(c.scanLimited ? '继续扫描' : '下一页'),
                ),
            ],
            if (preview != null) ...[
              const Divider(),
              Text(
                preview.delete ? '删除预览' : '保存预览',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '条目 ${preview.entryId} · ${preview.expectedVersion == null ? '新建' : '基于版本 ${preview.expectedVersion}'}',
              ),
              if (preview.prior != null)
                ExpansionTile(
                  title: const Text('原内容预览'),
                  children: [
                    SelectableText(preview.prior!.title),
                    SelectableText(preview.prior!.content),
                    if (preview.prior!.nextByte != null)
                      const Text('这里只展示原内容的首段。'),
                  ],
                ),
              if (!preview.delete) ...[
                SelectableText(preview.title ?? ''),
                SelectableText(preview.content ?? ''),
                Text(preview.enabled == true ? '保存后启用' : '保存后禁用'),
              ],
              Text(
                preview.delete
                    ? '确认后删除此条目，相关旧上下文将不能继续引用。'
                    : '确认后作为你的声明保存；已有的来源权限约束仍然有效。',
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('memory-confirm'),
                    onPressed: c.busy ? null : () => unawaited(c.approve()),
                    child: Text(preview.delete ? '确认删除' : '确认保存'),
                  ),
                  TextButton(
                    onPressed: c.busy
                        ? null
                        : () {
                            if (preview.delete && preview.prior != null) {
                              final prior = preview.prior!;
                              unawaited(
                                c.readEntry(
                                  api.MemorySummary(
                                    entryId: prior.entryId,
                                    version: prior.version,
                                    title: prior.title,
                                    enabled: prior.enabled,
                                    origin: prior.origin,
                                    contentBytes: prior.totalBytes,
                                  ),
                                ),
                              );
                              return;
                            }
                            final value = c.editPreview();
                            if (value == null) return;
                            setState(() {
                              title.text = value.title ?? '';
                              content.text = value.content ?? '';
                              enabled = value.enabled ?? true;
                              newEntry = true;
                            });
                          },
                    child: const Text('重新编辑'),
                  ),
                ],
              ),
            ] else if (newEntry || c.entry != null) ...[
              const Divider(),
              Text(
                c.targetVersion == null ? '新建条目' : '条目版本 ${c.targetVersion}',
              ),
              TextField(
                key: const Key('memory-title'),
                controller: title,
                readOnly: !c.canWrite || c.busy,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              TextField(
                key: const Key('memory-content'),
                controller: content,
                readOnly: !c.canWrite || c.busy,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(labelText: '内容'),
              ),
              if (c.canWrite) ...[
                CheckboxListTile(
                  value: enabled,
                  onChanged: c.busy
                      ? null
                      : (v) => setState(() => enabled = v ?? true),
                  title: const Text('启用条目'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('memory-preview'),
                      onPressed: c.busy
                          ? null
                          : () => unawaited(
                              c.prepare(
                                title: title.text,
                                content: content.text,
                                enabled: enabled,
                              ),
                            ),
                      child: const Text('生成保存预览'),
                    ),
                    if (c.targetVersion != null)
                      TextButton(
                        onPressed: c.busy
                            ? null
                            : () => unawaited(
                                c.prepare(
                                  title: '',
                                  content: '',
                                  enabled: false,
                                  delete: true,
                                ),
                              ),
                        child: const Text('生成删除预览'),
                      ),
                  ],
                ),
              ],
            ],
            if (scope != null && c.commands is MemoryDraftDirectory) ...[
              TextButton(
                onPressed: c.busy ? null : () => unawaited(c.discoverDrafts()),
                child: const Text('查找我的待确认草稿'),
              ),
              for (final draft in c.drafts)
                ListTile(
                  title: Text('待确认条目 ${draft.entryId}'),
                  subtitle: Text(draft.draftId),
                  trailing: Wrap(
                    children: [
                      TextButton(
                        onPressed: c.busy || !c.canWrite
                            ? null
                            : () => unawaited(c.openDraft(draft)),
                        child: const Text('重新审阅'),
                      ),
                      TextButton(
                        onPressed: c.busy
                            ? null
                            : () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('作废这份草稿？'),
                                    content: Text(
                                      '条目 ${draft.entryId} 的待确认内容将被清除。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('返回'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('确认作废'),
                                      ),
                                    ],
                                  ),
                                );
                                if (yes == true && mounted) {
                                  await c.discardDraft(draft);
                                }
                              },
                        child: const Text('作废'),
                      ),
                    ],
                  ),
                ),
              if (c.draftAfter != null)
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () => unawaited(c.discoverDrafts(more: true)),
                  child: const Text('更多草稿'),
                ),
            ],
            if (c.pendingRequest != null) ...[
              const Divider(),
              TextButton(
                onPressed: c.busy ? null : () => unawaited(c.inspectPending()),
                child: const Text('查询上次请求结果'),
              ),
              if (c.receipt?.state == 'pending' && c.canWrite)
                TextButton(
                  onPressed: c.busy ? null : () => unawaited(c.reviewPending()),
                  child: const Text('恢复待确认预览'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
