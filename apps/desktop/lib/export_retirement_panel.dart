import 'package:flutter/material.dart';

import 'export_retirement_controller.dart';

class ExportRetirementPanel extends StatelessWidget {
  const ExportRetirementPanel({super.key, required this.controller});
  final ExportRetirementController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller, v = c.review, inspection = c.inspection;
      if (c.read == null && c.error == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const Text('导出文件保留区'),
          const Text('经单独批准后移出目标或暂存位置，数据保留在原目录的保留区。不会释放空间；当前版本尚无恢复按钮。'),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null)
            Text(
              c.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (c.notice != null) Text(c.notice!),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.canPrepare('target')
                    ? () => c.prepare('target')
                    : null,
                child: const Text('选择目录并预览移出目标'),
              ),
              OutlinedButton(
                onPressed: c.canPrepare('staged')
                    ? () => c.prepare('staged')
                    : null,
                child: const Text('选择目录并预览移出暂存'),
              ),
              OutlinedButton(
                onPressed: c.busy ? null : () => c.refresh(),
                child: const Text('查询移出记录'),
              ),
            ],
          ),
          if (v != null) ...[
            SelectableText('目录：${c.access!.displayDirectory}'),
            Text('待移出：${v.choice == 'target' ? '目标' : '暂存'} ${v.fileName}'),
            Text('大小：${v.observed.bytes} 字节'),
            SelectableText('SHA-256：${v.observed.sha256}'),
            SelectableText('批准摘要：${v.digest}'),
            FilledButton(
              key: const Key('approve-export-retirement'),
              onPressed: c.busy ? null : c.approve,
              child: const Text('确认移入保留区'),
            ),
          ],
          for (final r in c.records)
            ListTile(
              title: Text(switch (r.state) {
                'retained' => '已移入保留区',
                'prepared' => '已准备，未确认移出',
                'dispatching' => '已派发，结果未确认',
                _ => '结果待核对',
              }),
              subtitle: SelectableText(r.retirementId),
              trailing: TextButton(
                key: Key('inspect-retirement-${r.retirementId}'),
                onPressed: c.busy ? null : () => c.inspect(r),
                child: const Text('检查保留区'),
              ),
            ),
          if (c.hasMore)
            TextButton(
              onPressed: c.busy ? null : () => c.refresh(more: true),
              child: const Text('更多移出记录'),
            ),
          if (inspection != null) ...[
            Text(
              !inspection.capsuleBound
                  ? '没有可验证的保留区绑定，不能判断是否发生过移出。'
                  : inspection.retained!.kind == 'missing'
                  ? '绑定有效，但保留项当前不存在。'
                  : inspection.retained!.matchesApprovedArtifact
                  ? '保留区内容当前匹配导出包。'
                  : '保留项存在差异或无法安全读取。',
            ),
            if (inspection.recordedState == 'unknown')
              const Text('记录仍待核对，匹配结果不会自动确认成功。'),
          ],
        ],
      );
    },
  );
}
