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
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本地模型', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (view != null) ...[
                if (view.profileId != null)
                  DropdownButtonFormField<String>(
                    key: ValueKey('model-profile-${view.selectionRevision}'),
                    initialValue: view.profileId,
                    decoration: const InputDecoration(labelText: '本地模型配置'),
                    items: const [
                      DropdownMenuItem(
                        value: 'local-small',
                        child: Text('Qwen2.5 0.5B'),
                      ),
                      DropdownMenuItem(
                        value: 'local-7b',
                        child: Text('Qwen2.5 7B · 审阅与补丁'),
                      ),
                    ],
                    onChanged: controller.canSelectProfile
                        ? (id) {
                            if (id != null) controller.selectProfile(id);
                          }
                        : null,
                  ),
                Text(view.modelName),
                if (view.inferenceThreads != null)
                  Text('本地推理使用 ${view.inferenceThreads} 个 CPU 线程'),
                if (view.profileId == 'local-7b') ...[
                  const Text('选择合并后的 Q4_K_M GGUF 文件。导入前可以用下方摘要核对本地文件。'),
                  SelectableText('SHA-256  ${view.modelSha256}'),
                ],
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
              const Text('使用本机 CPU；只接受当前清单中的模型文件。'),
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
                  if (view != null &&
                      !view.installed &&
                      view.profileId != 'local-7b')
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
                                    '从 Hugging Face 的固定模型版本下载 ${view.modelName}（${view.modelBytes} 字节）。下载完成后会核对文件摘要。工作区文件和会话文本保留在本机。',
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
