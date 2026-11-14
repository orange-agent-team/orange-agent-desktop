import 'package:flutter/material.dart';

import 'export_inspection_controller.dart';
import 'src/rust/api/host.dart';

class ExportInspectionPanel extends StatelessWidget {
  const ExportInspectionPanel({super.key, required this.controller});
  final ExportInspectionController controller;
  String describe(ExportObservedFileView file) => switch (file.kind) {
    'missing' => '不存在',
    'refused' => '当前类型或大小不符合检查条件',
    'regular' when file.matchesApprovedArtifact => '内容匹配已批准的数据包',
    'regular' when file.validExportDocument => '是有效数据包，但与本次预览不同',
    _ => '文件存在，内容与本次预览不同',
  };
  Future<void> close() async {
    try {
      await controller.close();
    } catch (e, s) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'export inspection close',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final view = controller.view;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.busy) const LinearProgressIndicator(),
          if (controller.error != null)
            Text(
              controller.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (view != null) ...[
            const Divider(),
            Text('导出位置检查', style: Theme.of(context).textTheme.titleSmall),
            SelectableText('检查目录：${controller.access!.displayDirectory}'),
            SelectableText('目标文件：${view.fileName}'),
            Text(
              view.recordedState == 'unknown'
                  ? '记录仍待核对。匹配结果只描述当前文件。'
                  : view.recordedState == 'succeeded'
                  ? '有已确认的导出回执；以下显示当前文件状态。'
                  : '记录尚未确认完成；以下显示当前文件状态。',
            ),
            Text('目标：${describe(view.target)}'),
            Text('暂存：${describe(view.staged)}'),
            if (view.target.bytes != null) Text('目标大小：${view.target.bytes} 字节'),
            if (view.target.sha256 != null)
              SelectableText('目标 SHA-256：${view.target.sha256}'),
            const Text('本次检查只读取状态。'),
          ],
          if (view != null || controller.busy || controller.error != null)
            OutlinedButton(onPressed: close, child: const Text('结束导出检查')),
        ],
      );
    },
  );
}
