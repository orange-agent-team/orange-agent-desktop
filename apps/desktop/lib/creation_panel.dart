import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart';

const _platform = MethodChannel('orange_agent/platform');

/// Owns native write selections separately from read access and Run approval.
class CreationPanel extends StatefulWidget {
  const CreationPanel({
    super.key,
    required this.host,
    required this.workspaces,
    required this.onChanged,
    required this.onStopping,
  });
  final HostView host;
  final List<WorkspaceView> workspaces;
  final ValueChanged<List<CreationAccessView>> onChanged;
  final ValueChanged<String> onStopping;
  @override
  State<CreationPanel> createState() => _CreationPanelState();
}

class _CreationPanelState extends State<CreationPanel> {
  final Map<String, String> selections = {};
  List<CreationAccessView> grants = [];
  bool busy = false;
  String? error;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant CreationPanel oldWidget) {
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
            library: 'creation scope cleanup',
          ),
        );
      });
    }
    super.dispose();
  }

  Future<void> release(String token) async {
    // Never release native rights if Runtime drain was not confirmed, including
    // a closed Host. The native owner retains that scope until application exit.
    await suspendCreationSelection(
      handle: widget.host.handle,
      requestId: token,
    );
    await _platform.invokeMethod<void>('releaseCreationSelection', {
      'selectionId': token,
    });
  }

  String describe(Object failure) => switch (failure) {
    BridgeError(code: 'CREATION_WORKSPACE_MISMATCH') => '请选择与只读工作区相同的文件夹。',
    BridgeError(code: 'CREATION_SELECTION_CLOSED') => '这次目录选择已关闭，请重新选择。',
    BridgeError(code: 'WORKSPACE_SESSION_ACCESS_REQUIRED') => '请先恢复该工作区的只读访问。',
    BridgeError(code: 'WORKSPACE_RECOVERY_REQUIRED') =>
      '该目录有尚未确认的执行结果，不能重新授予创建权限。',
    BridgeError(code: 'CREATION_PERMISSION_CHANGED') => '权限版本已变化，请刷新后重试。',
    _ => '创建权限操作未完成，请核对目录权限和当前状态。',
  };
  Future<void> refresh() async {
    final generation = ++epoch;
    await Future<void>.delayed(Duration.zero);
    if (!mounted || generation != epoch) return;
    try {
      final rows = <CreationAccessView>[];
      for (final workspace in widget.workspaces) {
        rows.addAll(
          await listCreationAccess(
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
    if (busy) return;
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
        'chooseCreationWorkspace',
      );
      if (selection == null) return;
      final token = selection['selectionId'], path = selection['path'];
      if (token is! String || path is! String) {
        throw const FormatException('Invalid selection');
      }
      pending = token;
      if (!mounted) return;
      final grant = await authorizeCreationAccess(
        handle: widget.host.handle,
        workspaceId: workspace.workspaceId,
        requestId: token,
        selectedDirectory: path,
      );
      if (!mounted) return;
      if (grant.sessionToken != token ||
          !grant.permissionActive ||
          grant.workspaceId != workspace.workspaceId) {
        throw const FormatException('Creation scope was not published');
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
              library: 'creation scope cleanup',
            ),
          );
          if (mounted) setState(() => error = '写入访问收尾未确认，请关闭应用后再继续。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke(CreationAccessView grant) async {
    if (busy) return;
    widget.onStopping(grant.consentId);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await revokeCreationAccess(
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
          Text('文件创建权限', style: Theme.of(context).textTheme.titleLarge),
          const Text('单独选择文件夹后，才可让新会话提出文件创建请求。每个文件都需要再次批准；不会覆盖现有文件或执行程序。'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final workspace in widget.workspaces.where(
            (w) => w.permissionActive && w.sessionAccess,
          )) ...[
            const SizedBox(height: 8),
            Text(workspace.displayPath),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => choose(workspace),
                  child: const Text('选择文件夹以允许新建'),
                ),
                for (final grant in grants.where(
                  (c) =>
                      c.workspaceId == workspace.workspaceId &&
                      c.permissionActive,
                ))
                  TextButton(
                    onPressed: busy ? null : () => revoke(grant),
                    child: const Text('撤销创建权限'),
                  ),
              ],
            ),
          ],
          TextButton(
            onPressed: busy ? null : refresh,
            child: const Text('核对创建权限'),
          ),
        ],
      ),
    ),
  );
}
