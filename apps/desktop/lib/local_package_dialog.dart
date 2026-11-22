import 'dart:convert';

import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'src/rust/api/host.dart';

Future<bool> manageLocalPackage(
  BuildContext context,
  LocalPackageCommands commands, {
  LocalSkillChoice? remove,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PackageDialog(commands: commands, remove: remove),
      ) ??
      false;
}

class _PackageDialog extends StatefulWidget {
  const _PackageDialog({required this.commands, this.remove});
  final LocalPackageCommands commands;
  final LocalSkillChoice? remove;
  @override
  State<_PackageDialog> createState() => _PackageState();
}

class _PackageState extends State<_PackageDialog> {
  final manifest = TextEditingController();
  LocalPackageReview? review;
  String? failure;
  bool busy = false;
  bool get removing => widget.remove != null;

  @override
  void initState() {
    super.initState();
    final current = widget.remove;
    if (current != null) {
      manifest.text = jsonEncode({
        'id': current.skillId,
        'version': current.version,
        'scenario': current.scenario,
        'name': current.displayName,
        'instruction': current.instruction,
        'tools': current.tools,
      });
      inspect();
    }
  }

  @override
  void dispose() {
    manifest.dispose();
    super.dispose();
  }

  Future<void> inspect() async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
      review = null;
    });
    try {
      final candidate = await widget.commands.reviewPackage(manifest.text);
      if (!mounted) return;
      if (removing &&
          (!candidate.installed || candidate.digest != widget.remove!.digest)) {
        setState(() => failure = '所选版本已变化，请关闭窗口并重新读取目录。');
      } else {
        setState(() => review = candidate);
      }
    } catch (_) {
      if (mounted) {
        setState(() => failure = '审核失败。请核对 JSON 的字段、命名空间、工具以及同版本的内容。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    final accepted = review;
    if (busy || accepted == null || accepted.installed != removing) return;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      if (removing) {
        await widget.commands.uninstallPackage(accepted);
      } else {
        await widget.commands.installPackage(manifest.text, accepted);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          review = null;
          failure = '未能确认当前安装状态，请重新审核。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reviewed = review;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(removing ? '卸载本地模板' : '安装本地模板'),
        content: SizedBox(
          width: 510,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!removing && reviewed == null)
                  TextField(
                    key: const ValueKey("local-package-manifest"),
                    controller: manifest,
                    enabled: !busy,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 16384,
                    decoration: const InputDecoration(
                      labelText: '模板 JSON',
                      helperText: '接受 local. 命名空间的只读声明式模板。',
                    ),
                  ),
                if (busy) const LinearProgressIndicator(),
                if (failure != null) Text(failure!),
                if (reviewed != null) ...[
                  SelectableText(
                    '${reviewed.displayName} · ${reviewed.version}',
                  ),
                  SelectableText(reviewed.skillId),
                  const SizedBox(height: 12),
                  SelectableText(reviewed.instruction),
                  const SizedBox(height: 12),
                  Text(
                    reviewed.tools.isEmpty
                        ? '工具权限：无'
                        : '可申请工具：${reviewed.tools.join('、')}',
                  ),
                  SelectableText('SHA-256  ${reviewed.digest}'),
                  Text(
                    removing
                        ? '卸载后，使用此版本的旧会话将失去续跑权限。'
                        : reviewed.installed
                        ? '此版本已经安装。'
                        : '安装后仍需单独启用此版本。',
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
          if (!removing && reviewed != null)
            TextButton(
              onPressed: busy ? null : () => setState(() => review = null),
              child: const Text('返回编辑'),
            ),
          if (reviewed == null)
            FilledButton(
              onPressed: busy ? null : inspect,
              child: const Text('审核模板'),
            ),
          if (reviewed != null && reviewed.installed == removing)
            FilledButton(
              onPressed: busy ? null : confirm,
              child: Text(removing ? '确认卸载' : '确认安装'),
            ),
        ],
      ),
    );
  }
}
