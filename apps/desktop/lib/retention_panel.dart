import 'package:flutter/material.dart';

import 'retention_controller.dart';
import 'export_panel.dart';
import 'src/rust/api/host.dart';

class RetentionPanel extends StatelessWidget {
  const RetentionPanel({
    super.key,
    required this.controller,
    required this.supported,
  });
  final RetentionController controller;
  final bool supported;
  String file(RecoveryFileStatusView value) => switch (value.kind) {
    'missing' => '不存在',
    'regular' =>
      '${value.bytes} 字节 · ${value.matchesOriginalContent
          ? '与原始内容一致'
          : value.matchesResultContent
          ? '与发布内容一致'
          : '内容已变化'}',
    _ => '当前文件不符合检查条件',
  };
  Future<void> stop() async {
    try {
      await controller.stop();
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'retention panel cleanup',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller, view = c.snapshot, review = c.review;
      return Card(
        child: ExpansionTile(
          title: const Text('保留原件管理'),
          subtitle: const Text('查看保留版本与预留额度，确认原地归档'),
          onExpansionChanged: (open) {
            if (open && supported && !c.loaded) c.refresh();
          },
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('归档只调整预留额度的记账分类。文件留在原目录，不会释放磁盘空间，也不是不可变备份。'),
                  if (!supported) const Text('此平台尚未提供保留原件管理。'),
                  if (supported) ...[
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: c.busy ? null : () => c.refresh(),
                          child: const Text('刷新保留记录'),
                        ),
                        OutlinedButton(
                          onPressed: c.busy || c.nextCursor == null
                              ? null
                              : () => c.refresh(older: true),
                          child: const Text('更早的运行'),
                        ),
                        OutlinedButton(
                          onPressed: stop,
                          child: const Text('结束原件管理'),
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
                    if (c.notice != null) Text(c.notice!),
                    for (final run in c.runs)
                      ListTile(
                        title: Text(run.runId),
                        trailing: TextButton(
                          onPressed: c.busy ? null : () => c.selectRun(run),
                          child: const Text('查看保留操作'),
                        ),
                      ),
                    if (c.selected != null && c.operations.isEmpty && !c.busy)
                      const Text('本页没有可管理的保留记录。未解决的改动需先进行恢复检查。'),
                    for (final op in c.operations)
                      ListTile(
                        title: Text(op),
                        selected: c.operation == op,
                        leading: Icon(
                          c.operation == op
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: c.busy ? null : () => c.selectOperation(op),
                      ),
                    if (c.operationCursor != null && c.selected != null)
                      TextButton(
                        onPressed: c.busy
                            ? null
                            : () => c.selectRun(c.selected!, older: true),
                        child: const Text('更多保留操作'),
                      ),
                    FilledButton(
                      onPressed: c.busy || c.operation == null
                          ? null
                          : c.chooseAndInspect,
                      child: const Text('选择原目录并检查保留版本'),
                    ),
                    if (view != null) ...[
                      SelectableText('文件：${view.path}'),
                      Text('保留原件：${file(view.original)}'),
                      Text('暂存版本：${file(view.staged)}'),
                      Text(
                        '本目录活动预留：${view.resourceActiveRecords} 条 / ${view.resourceActiveReservedBytes} 字节',
                      ),
                      Text(
                        '当前用户归档预留：${view.ownerArchiveRecords} / ${view.ownerArchiveRecordLimit} 条，${view.ownerArchiveReservedBytes} / ${view.ownerArchiveLimitBytes} 字节',
                      ),
                      const Text('以上是准入预留额度，不是实际磁盘占用。'),
                      if (view.archivedReviewId != null)
                        Text(
                          view.changedSinceArchival == true
                              ? '已归档，但保留文件在登记后发生了变化。'
                              : '已登记为原地保留。',
                        ),
                      if (view.archivedReviewId == null)
                        OutlinedButton(
                          onPressed: c.busy ? null : c.prepare,
                          child: const Text('生成归档预览'),
                        ),
                    ],
                    if (review != null) ...[
                      SelectableText('待确认文件：${review.path}'),
                      Text(
                        '原件：${file(review.original)}；暂存：${file(review.staged)}',
                      ),
                      Text(
                        '本次归档预留：${review.archiveReservedBytes} 字节。确认后文件仍留在原处。',
                      ),
                      SelectableText('预览摘要：${review.digest}'),
                      FilledButton(
                        onPressed: c.busy ? null : c.approve,
                        child: const Text('确认本次原地归档'),
                      ),
                    ],
                    ExportPanel(controller: c),
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
