import 'package:flutter/material.dart';

import 'retention_controller.dart';
import 'export_inspection_panel.dart';

class ExportPanel extends StatelessWidget {
  const ExportPanel({super.key, required this.controller});
  final RetentionController controller;
  Future<void> close() async {
    try {
      await controller.closeExport();
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: s, library: 'export cleanup'),
      );
    }
  }

  String state(String value) => switch (value) {
    'succeeded' => '已确认导出',
    'prepared' => '待确认；重开后需重新准备',
    'dispatching' => '派发中，结果待核对',
    _ => '结果待核对，未自动重试',
  };
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller, access = c.exportAccess, review = c.exportReview;
      if (c.exportCommands == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          Text('导出保留版本', style: Theme.of(context).textTheme.titleMedium),
          const Text('数据包包含可直接解码的文件内容，不是加密备份。仅新建文件，不覆盖目标，也不删除原件。'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.busy || c.access == null
                    ? null
                    : c.chooseExportDestination,
                child: const Text('单独选择导出目录'),
              ),
              OutlinedButton(
                onPressed: access == null ? null : close,
                child: const Text('关闭导出目标'),
              ),
              OutlinedButton(
                onPressed: c.busy || c.operation == null
                    ? null
                    : () => c.refreshExports(),
                child: const Text('刷新导出记录'),
              ),
            ],
          ),
          if (access != null) ...[
            SelectableText('目标目录：${access.displayDirectory}'),
            TextFormField(
              initialValue: c.exportFileName,
              enabled: !c.busy,
              onChanged: c.setExportFileName,
              decoration: const InputDecoration(
                labelText: '导出文件名',
                helperText: '以 .orange-retained.json 结尾；已有文件不会被覆盖',
              ),
            ),
            DropdownButton<String>(
              value: c.exportChoice,
              onChanged: c.busy
                  ? null
                  : (value) {
                      if (value != null) c.setExportChoice(value);
                    },
              items: const [
                DropdownMenuItem(value: 'both', child: Text('全部现存保留版本')),
                DropdownMenuItem(value: 'original', child: Text('保留原件位置的当前内容')),
                DropdownMenuItem(value: 'staged', child: Text('暂存位置的当前内容')),
              ],
            ),
            OutlinedButton(
              onPressed: c.busy ? null : c.prepareExport,
              child: const Text('生成导出预览'),
            ),
          ],
          if (review != null) ...[
            SelectableText('源文件：${review.sourcePath} → ${review.fileName}'),
            for (final entry in review.entries)
              Text(
                '${entry.role == 'original' ? '原件位置' : '暂存位置'}：${entry.bytes} 字节，${entry.matchesReviewedOriginal
                    ? '与审阅原件一致'
                    : entry.matchesReviewedResult
                    ? '与审阅结果一致'
                    : '当前内容已变化'}',
              ),
            Text('数据包大小：${review.artifactBytes} 字节'),
            SelectableText('数据包 SHA-256：${review.artifactSha256}'),
            SelectableText('确认摘要：${review.digest}'),
            FilledButton(
              onPressed: c.busy ? null : c.approveExport,
              child: const Text('确认创建这个导出文件'),
            ),
          ],
          if (c.exportNotice != null) Text(c.exportNotice!),
          if (c.exportRecords.isNotEmpty)
            const Text('以下是持久记录，不代表目标文件此后未被外部修改。'),
          for (final record in c.exportRecords)
            ListTile(
              title: Text(record.exportId),
              subtitle: Text(state(record.state)),
              trailing: c.exportInspection == null
                  ? null
                  : TextButton(
                      key: Key('inspect-export-${record.exportId}'),
                      onPressed: c.busy
                          ? null
                          : () => c.inspectExportRecord(record),
                      child: const Text('检查位置'),
                    ),
            ),
          if (c.exportInspection != null)
            ExportInspectionPanel(controller: c.exportInspection!),
          if (c.exportCursor != null)
            TextButton(
              onPressed: c.busy ? null : () => c.refreshExports(older: true),
              child: const Text('更多导出记录'),
            ),
        ],
      );
    },
  );
}
