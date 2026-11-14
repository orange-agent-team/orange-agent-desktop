import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart';

const _platform = MethodChannel('orange_agent/platform');

/// Owns native write selections separately from read access and Run approval.
class EditingPanel extends StatefulWidget {
  const EditingPanel({
    super.key,
    required this.host,
    required this.workspaces,
    required this.onChanged,
    required this.onStopping,
  });
  final HostView host;
  final List<WorkspaceView> workspaces;
  final ValueChanged<List<EditingAccessView>> onChanged;
  final ValueChanged<String> onStopping;
  @override
  State<EditingPanel> createState() => _EditingPanelState();
}

class _EditingPanelState extends State<EditingPanel> {
  final Map<String, String> selections = {};
  List<EditingAccessView> grants = [];
  bool busy = false;
  String? error;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant EditingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    String key(List<WorkspaceView> values) => values
        .map((w) => '${w.workspaceId}:${w.permissionVersion}:${w.sessionToken}')
        .join('|');
    if (key(oldWidget.workspaces) != key(widget.workspaces)) refresh();
  }

  @override
  void dispose() {
    epoch++;
    for (final token in selections.values) {
      release(token).catchError((Object failure, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: failure,
            stack: stack,
            library: 'editing scope cleanup',
          ),
        );
      });
    }
    super.dispose();
  }

  Future<void> release(String token) async {
    // Never release native rights if Runtime drain was not confirmed, including
    // a closed Host. The native owner retains that scope until application exit.
    await suspendEditingSelection(handle: widget.host.handle, requestId: token);
    await _platform.invokeMethod<void>('releaseEditingSelection', {
      'selectionId': token,
    });
  }

  String describe(Object failure) => switch (failure) {
    BridgeError(code: 'EDITING_WORKSPACE_MISMATCH') => '请选择与只读工作区相同的文件夹。',
    BridgeError(code: 'EDITING_SELECTION_CLOSED') => '这次目录选择已关闭，请重新选择。',
    BridgeError(code: 'WORKSPACE_SESSION_ACCESS_REQUIRED') => '请先恢复该工作区的只读访问。',
    BridgeError(code: 'WORKSPACE_RECOVERY_REQUIRED') =>
      '该目录有尚未确认的执行结果，不能重新授予编辑权限。',
    BridgeError(code: 'EDITING_PERMISSION_CHANGED') => '权限版本已变化，请刷新后重试。',
    _ => '编辑权限操作未完成，请核对目录权限和当前状态。',
  };
  Future<void> refresh() async {
    if (!widget.host.availableEditTools.contains('apply_patch')) return;
    final generation = ++epoch;
    await Future<void>.delayed(Duration.zero);
    if (!mounted || generation != epoch) return;
    try {
      final rows = <EditingAccessView>[];
      for (final workspace in widget.workspaces) {
        rows.addAll(
          await listEditingAccess(
            handle: widget.host.handle,
            workspaceId: workspace.workspaceId,
          ),
        );
      }
      if (!mounted || generation != epoch) return;
      final available = widget.workspaces
          .where((w) => w.permissionActive && w.sessionAccess)
          .map((w) => w.workspaceId)
          .toSet();
      for (final grant in rows.where(
        (c) => !available.contains(c.workspaceId) || !c.permissionActive,
      )) {
        final token = selections[grant.consentId];
        if (token != null) {
          widget.onStopping(grant.consentId);
          await release(token);
          selections.remove(grant.consentId);
        }
      }
      if (!mounted || generation != epoch) return;
      setState(() {
        grants = rows;
        error = null;
      });
      widget.onChanged(
        rows
            .where(
              (c) =>
                  available.contains(c.workspaceId) &&
                  c.permissionActive &&
                  c.sessionToken != null,
            )
            .toList(),
      );
    } catch (failure) {
      if (mounted && generation == epoch) {
        setState(() {
          error = describe(failure);
          grants = [];
        });
        widget.onChanged(const []);
      }
    }
  }

  Future<void> choose(WorkspaceView workspace) async {
    if (busy || !widget.host.availableEditTools.contains('apply_patch')) return;
    setState(() {
      busy = true;
      error = null;
    });
    String? pending;
    try {
      if (!Platform.isMacOS) {
        throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
      }
      final selection = await _platform.invokeMapMethod<String, dynamic>(
        'chooseEditingWorkspace',
      );
      if (selection == null) return;
      final token = selection['selectionId'], path = selection['path'];
      if (token is! String || path is! String) {
        throw const FormatException('Invalid selection');
      }
      pending = token;
      if (!mounted) return;
      final grant = await authorizeEditingAccess(
        handle: widget.host.handle,
        workspaceId: workspace.workspaceId,
        requestId: token,
        selectedDirectory: path,
      );
      if (!mounted) return;
      if (grant.sessionToken != token ||
          !grant.permissionActive ||
          grant.workspaceId != workspace.workspaceId) {
        throw const FormatException('Editing scope was not published');
      }
      final old = selections[grant.consentId];
      selections[grant.consentId] = token;
      pending = null;
      if (old != null && old != token) await release(old);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = describe(failure));
    } finally {
      if (pending != null) {
        try {
          await release(pending);
        } catch (failure) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: failure,
              library: 'editing scope cleanup',
            ),
          );
          if (mounted) setState(() => error = '写入访问收尾未确认，请关闭应用后再继续。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke(EditingAccessView grant) async {
    if (busy) return;
    widget.onStopping(grant.consentId);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await revokeEditingAccess(
        handle: widget.host.handle,
        consentId: grant.consentId,
        expectedVersion: grant.permissionVersion,
      );
      final token = selections[grant.consentId];
      if (token != null) {
        await release(token);
        selections.remove(grant.consentId);
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
          if (!widget.host.availableEditTools.contains('apply_patch'))
            const Text('当前平台尚不支持文件编辑。'),
          Text('文件编辑权限', style: Theme.of(context).textTheme.titleLarge),
          const Text('单独选择文件夹后，才可让新会话提出现有文件编辑请求。每次修改都需核对实际差异后批准；不允许删除文件或执行程序。'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final workspace in widget.workspaces.where(
            (w) =>
                w.permissionActive &&
                w.sessionAccess &&
                widget.host.availableEditTools.contains('apply_patch'),
          )) ...[
            const SizedBox(height: 8),
            Text(workspace.displayPath),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => choose(workspace),
                  child: const Text('选择文件夹以允许编辑'),
                ),
                for (final grant in grants.where(
                  (c) =>
                      c.workspaceId == workspace.workspaceId &&
                      c.permissionActive,
                ))
                  TextButton(
                    onPressed: busy ? null : () => revoke(grant),
                    child: const Text('撤销编辑权限'),
                  ),
              ],
            ),
          ],
          TextButton(
            onPressed: busy ? null : refresh,
            child: const Text('核对编辑权限'),
          ),
        ],
      ),
    ),
  );
}
