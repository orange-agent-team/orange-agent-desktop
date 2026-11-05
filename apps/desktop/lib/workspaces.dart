import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart';

const _platform = MethodChannel('orange_agent/platform');

class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({
    super.key,
    required this.host,
    this.onChanged,
    this.onAccessStopping,
    this.onOpenRun,
  });
  final HostView host;
  final void Function(List<WorkspaceView>)? onChanged;
  final void Function(String)? onAccessStopping;
  final void Function(RunSummary)? onOpenRun;
  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  List<WorkspaceView>? workspaces;
  final Map<String, String> selections = {};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    for (final entry in selections.entries) {
      releaseSelection(entry.value)
          .catchError((Object failure, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: failure,
                stack: stack,
                library: 'workspace scope cleanup',
              ),
            );
          });
    }
    super.dispose();
  }

  Future<void> releaseSelection(String id) async {
    try {
      // ID is known before authorization dispatch, even if its reply is lost.
      await suspendWorkspaceSelection(
        handle: widget.host.handle,
        requestId: id,
      );
    } on BridgeError catch (error) {
      if (error.code != 'STALE_HOST_HANDLE') {
        rethrow;
      }
    }
    await _platform.invokeMethod<void>('releaseWorkspaceSelection', {
      'selectionId': id,
    });
  }

  String describe(Object failure) {
    if (failure is BridgeError) {
      return switch (failure.code) {
        'WORKSPACE_PRIVATE_ROOT' => '这个目录包含受保护的应用数据或系统路径，请选择更具体的项目目录。',
        'WORKSPACE_RECOVERY_REQUIRED' => '该目录仍有关联的未知执行结果，需要先处理恢复记录。',
        'WORKSPACE_REVOKED' => '此授权已经撤销，请重新选择目录。',
        'WORKSPACE_IDENTITY_CHANGED' => '目录身份已经改变，原授权已失效，请重新选择。',
        'WORKSPACE_IDENTITY_UNAVAILABLE' => '当前文件系统无法提供可安全恢复的目录身份。',
        'WORKSPACE_CONFLICT' => '授权版本已变化，请刷新后再操作。',
        'STALE_HOST_HANDLE' => '本地连接已关闭，请重新打开应用。',
        _ => '无法完成工作区操作，请检查目录权限后重试。',
      };
    }
    return '系统目录选择器暂时不可用，请重试。';
  }

  Future<void> refresh() async {
    try {
      final rows = await listWorkspaces(
        handle: widget.host.handle,
        includeRevoked: false,
      );
      if (mounted) {
        setState(() {
          workspaces = rows;
          error = null;
        });
        widget.onChanged?.call(rows);
      }
    } catch (failure) {
      if (mounted) setState(() => error = describe(failure));
    }
  }

  Future<void> choose() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    String? pending;
    final handle = widget.host.handle;
    try {
      if (!Platform.isMacOS) {
        throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
      }
      final selected = await _platform.invokeMapMethod<String, dynamic>(
        'chooseWorkspace',
      );
      if (selected == null) return;
      final id = selected['selectionId'];
      final path = selected['path'];
      if (id is! String || path is! String) {
        throw const FormatException('Invalid selection');
      }
      pending = id;
      if (!mounted || widget.host.handle != handle) return;
      final workspace = await authorizeWorkspace(
        handle: handle,
        requestId: id,
        selectedDirectory: path,
      );
      if (!mounted || widget.host.handle != handle) return;
      final token = workspace.sessionToken;
      if (token == null) {
        throw const FormatException('Missing workspace session token');
      }
      final previous = selections[workspace.workspaceId];
      selections[workspace.workspaceId] = id;
      pending = null;
      if (previous != null) {
        await releaseSelection(previous);
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = describe(failure));
    } finally {
      if (pending != null) {
        try {
          await releaseSelection(pending);
        } catch (failure) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: failure,
              library: 'workspace scope cleanup',
            ),
          );
          if (mounted) setState(() => error = '系统访问收尾未确认，请关闭并重新打开应用。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> showRuns(WorkspaceView workspace) async {
    try {
      final page = await listRuns(
        handle: widget.host.handle,
        workspaceId: workspace.workspaceId,
        limit: 100,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: 380,
            child: page.runs.isEmpty
                ? const Center(child: Text('暂无运行记录'))
                : ListView(
                    children: [
                      for (final run in page.runs)
                        ListTile(
                          title: Text(run.runId),
                          subtitle: Text('${run.phase} · ${run.steps} 步'),
                          onTap: widget.onOpenRun == null
                              ? null
                              : () {
                                  Navigator.of(context).pop();
                                  widget.onOpenRun!(run);
                                },
                        ),
                      if (page.nextCursor != null)
                        const ListTile(title: Text('当前显示最近 100 条记录')),
                    ],
                  ),
          ),
        ),
      );
    } catch (failure) {
      if (mounted) setState(() => error = describe(failure));
    }
  }

  Future<void> revoke(WorkspaceView workspace) async {
    if (busy) return;
    widget.onAccessStopping?.call(workspace.workspaceId);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await revokeWorkspace(
        handle: widget.host.handle,
        workspaceId: workspace.workspaceId,
        expectedVersion: workspace.permissionVersion,
      );
      final selection = selections.remove(workspace.workspaceId);
      if (selection != null) {
        await releaseSelection(selection);
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = describe(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '工作区',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton.icon(
                onPressed: busy ? null : choose,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('选择文件夹'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('只读授权；应用重启后，请重新选择目录恢复本次访问。每次工具读取仍需明确批准。'),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (workspaces == null && error == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          if (workspaces?.isEmpty ?? false)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('尚未授权工作区'),
            ),
          for (final workspace in workspaces ?? <WorkspaceView>[])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(workspace.displayPath),
              subtitle: Text(
                workspace.sessionAccess ? '本次只读访问已授权' : '已记住目录，需重新选择以恢复访问',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: busy ? null : () => showRuns(workspace),
                    tooltip: '运行记录',
                    icon: const Icon(Icons.history),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => revoke(workspace),
                    child: const Text('撤销访问'),
                  ),
                ],
              ),
            ),
          if (error != null)
            TextButton(
              onPressed: busy ? null : refresh,
              child: const Text('刷新'),
            ),
        ],
      ),
    ),
  );
}
