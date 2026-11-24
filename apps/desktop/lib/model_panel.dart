import 'package:flutter/material.dart';

import 'model_controller.dart';

class ModelPanel extends StatelessWidget {
  const ModelPanel({super.key, required this.controller});
  final ModelController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final view = controller.view;
      final cache = controller.cacheView;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本地模型', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (view != null) ...[
                Text(view.modelName),
                Text(
                  '所需文件：${view.modelBytes} 字节 · ${view.installed ? '文件已校验' : '尚未导入'}',
                ),
                const SizedBox(height: 8),
                Text(switch (view.phase) {
                  'idle' => '服务未启动',
                  'starting' => '正在启动',
                  'ready' => '服务已就绪',
                  'stopping' => '正在停止',
                  'stopped' => '服务已停止',
                  'recovery_required' => '需要核对进程状态',
                  _ => '状态尚未确认',
                }),
              ],
              if (view?.failure != null)
                Text(
                  describeModelFailureCode(view!.failure!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Text('本机 CPU 处理会话文本和获准读取的文件，平台算力费用为 0。'),
              if (view != null && (!view.installed || view.failure != null))
                const ExpansionTile(
                  title: Text('本机资源不足时的选择'),
                  children: [
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '可下载或导入清单中的模型，也可以稍后继续。需要租用算力时，在用户 Web 重新选择可发送的内容和付款预算；批准上传前，桌面工作区文件和会话文本留在本机。',
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (view == null)
                    OutlinedButton(
                      onPressed: controller.busy ? null : controller.configure,
                      child: const Text('检查模型组件'),
                    ),
                  if (view != null)
                    OutlinedButton(
                      onPressed: controller.canInstall
                          ? controller.importFile
                          : null,
                      child: Text(controller.importing ? '正在导入…' : '导入模型文件'),
                    ),
                  if (view != null && !view.installed)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(controller.downloading ? '正在下载…' : '下载审核模型'),
                      onPressed: controller.canInstall
                          ? () async {
                              final approved = await showDialog<bool>(
                                context: context,
                                builder: (dialog) => AlertDialog(
                                  title: const Text('下载本地模型'),
                                  content: Text(
                                    '从 Hugging Face 下载审核版本的 ${view.modelName}（${view.modelBytes} 字节）。来源不可用时，可从已固定同一文件的 ModelScope 官方来源续传。完成后会核对文件摘要。工作区文件和会话文本保留在本机。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, false),
                                      child: const Text('返回'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, true),
                                      child: const Text('确认下载'),
                                    ),
                                  ],
                                ),
                              );
                              if (approved == true && context.mounted) {
                                await controller.download();
                              }
                            }
                          : null,
                    ),
                  if (controller.downloading)
                    TextButton(
                      onPressed: controller.cancelDownload,
                      child: const Text('取消下载'),
                    ),
                  if (controller.importing)
                    TextButton(
                      onPressed: controller.cancelImport,
                      child: const Text('取消导入'),
                    ),
                  if (view != null)
                    FilledButton(
                      onPressed: controller.canStart && view.phase != 'ready'
                          ? () async {
                              try {
                                await controller.start();
                              } catch (_) {
                                /* The controller records failure; no success state is synthesized. */
                              }
                            }
                          : null,
                      child: const Text('启动本地模型'),
                    ),
                  if (controller.canStop)
                    TextButton(
                      onPressed: controller.stopping ? null : controller.stop,
                      child: const Text('停止本地模型'),
                    ),
                  if (view != null)
                    TextButton(
                      onPressed: controller.refresh,
                      child: const Text('核对模型状态'),
                    ),
                ],
              ),
              if (view != null)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed:
                          controller.inspectingCache || controller.clearingCache
                          ? null
                          : controller.inspectCache,
                      child: Text(
                        controller.inspectingCache ? '正在核对缓存…' : '核对权重缓存',
                      ),
                    ),
                    if (controller.hasStaging)
                      TextButton(
                        onPressed: controller.busy || controller.inspectingCache
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (dialog) => AlertDialog(
                                    title: const Text('清除模型暂存？'),
                                    content: const Text(
                                      '下次获取该模型时需要重新传输或导入这些未完成的字节。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dialog, false),
                                        child: const Text('保留暂存'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(dialog, true),
                                        child: const Text('确认清除'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await controller.discardStaging();
                                }
                              },
                        child: const Text('清除未完成的模型文件'),
                      ),
                  ],
                ),
              if (cache != null) ...[
                Text(switch (cache.state) {
                  'absent' => '缓存中尚无权重',
                  'staged' => '存在尚未校验的暂存文件',
                  'verified' => '权重摘要已核验',
                  'invalid' => '缓存文件未通过完整性校验',
                  _ => '缓存状态未知',
                }),
                if (cache.downloadStagingBytes != null)
                  Text(
                    '下载暂存 ${cache.downloadStagingBytes} / ${cache.expectedBytes} 字节',
                  ),
                if (cache.importStagingBytes != null)
                  Text(
                    '导入暂存 ${cache.importStagingBytes} / ${cache.expectedBytes} 字节',
                  ),
                if (cache.readLeaseObserved == true) const Text('检测到权重文件正在被读取'),
                SelectableText('SHA-256  ${cache.sha256}'),
              ],
              if (controller.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: LinearProgressIndicator(),
                ),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (controller.notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(controller.notice!),
                ),
            ],
          ),
        ),
      );
    },
  );
}
