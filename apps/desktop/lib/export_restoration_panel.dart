import 'package:flutter/material.dart';

import 'export_restoration_controller.dart';
import 'src/rust/api/host.dart';

class ExportRestorationPanel extends StatelessWidget {
  const ExportRestorationPanel({super.key, required this.controller});
  final ExportRestorationController controller;
  String describe(ExportObservedFileView v) => switch (v.kind) {
    'missing' => '不存在',
    'regular' when v.matchesApprovedArtifact => '内容匹配批准的数据包',
    'regular' => '存在，内容与批准的数据包不同',
    _ => '无法安全读取当前对象',
  };
  Future<void> close() async {
    try {
      await controller.close();
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'export restoration close',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller, v = c.review, inspection = c.inspection;
      if (c.parent == null && c.error == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const Text('从保留区恢复副本'),
          const Text('创建完整数据包的新副本，保留区原件始终保留。已有目标不会被覆盖，也不会自动解包到原工作区。'),
          if (c.parent != null)
            SelectableText('保留记录：${c.parent!.retirementId}'),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null)
            Text(
              c.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (c.notice != null) Text(c.notice!),
          if (c.parent != null) ...[
            TextFormField(
              key: ValueKey('restore-name-${c.parent!.retirementId}'),
              initialValue: c.fileName,
              enabled: !c.busy,
              decoration: const InputDecoration(
                labelText: '恢复副本文件名',
                helperText: '以 .orange-retained.json 结尾',
              ),
              onChanged: c.setFileName,
            ),
            OutlinedButton(
              onPressed: c.canPrepare ? c.prepare : null,
              child: const Text('选择目录并预览恢复副本'),
            ),
          ],
          if (v != null) ...[
            SelectableText('恢复目录：${c.access!.displayDirectory}'),
            SelectableText('目标：${v.fileName}'),
            Text('副本大小：${v.source.bytes} 字节'),
            SelectableText('副本 SHA-256：${v.source.sha256}'),
            SelectableText('恢复批准摘要：${v.digest}'),
            FilledButton(
              key: const Key('approve-export-restoration'),
              onPressed: c.busy ? null : c.approve,
              child: const Text('确认创建恢复副本'),
            ),
          ],
          OutlinedButton(
            onPressed: c.busy ? null : () => c.refresh(),
            child: const Text('查询恢复记录'),
          ),
          for (final r in c.records)
            ListTile(
              title: Text(switch (r.state) {
                'succeeded' => '恢复副本已有确认回执',
                'prepared' => '恢复预览尚未批准',
                'dispatching' => '恢复已派发，结果未确认',
                _ => '恢复结果待核对',
              }),
              subtitle: SelectableText('${r.fileName}\n${r.restorationId}'),
              trailing: TextButton(
                key: Key('inspect-restoration-${r.restorationId}'),
                onPressed: c.busy ? null : () => c.inspect(r),
                child: const Text('检查恢复结果'),
              ),
            ),
          if (c.hasMore)
            TextButton(
              onPressed: c.busy ? null : () => c.refresh(more: true),
              child: const Text('更多恢复记录'),
            ),
          if (inspection != null) ...[
            Text('恢复目标：${describe(inspection.target)}'),
            Text('恢复暂存：${describe(inspection.staged)}'),
            if (inspection.recordedState == 'unknown')
              const Text('恢复记录仍待核对，内容匹配不会自动确认成功。'),
          ],
          OutlinedButton(onPressed: close, child: const Text('结束恢复管理')),
        ],
      );
    },
  );
}
