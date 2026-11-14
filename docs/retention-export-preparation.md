# 保留版本导出：桌面接线入口

固定Runtime c414feb16843f79bf6b85ef089591e9e68825910/schema18已通过显式归档导入，253项共享测试（含200Runtime）及消费端9Rust/Clippy/static/42组件测试通过。成对FRB仍只有既有接口；没有桌面导出按钮或目标选择功能，不能声称产品导出已完成。

匹配组件清单bed49e57c1f333c919f34702a4f7330e795cd4cd944f173607dd5a7a92e53499，无测试权重。旧候选已构建App仍是此前schema17入口，不是新Runtime18的原生包验证。

## Runtime接口

保留读取使用既有PatchRetentionGrant。另经明确目的目录选择调用authorize_retention_export_destination。prepare_retention_export返回不可序列化PreparedRetentionExport及精确预览（export_id/digest、文件名、数据包大小/摘要、版本信息和有效期）；不写文件。

approve_retention_export消耗准备结果，先持久派发再新建0600、非执行文件并排他发布；不覆盖已有目标、不删原件、不改变归档额度。retention_export_outcome按owner/Run/operation/export_id核对提交状态，不读取文件或恢复权限。回复丢失只查询，不自动重发。schema18重开把中断派发转unknown。普通Rust实际文件与真实旧schema17CLI升级/拒绝回退已验证，签名App Sandbox导出尚待验证。

## 接线顺序和关键约束

1. 为目的目录添加独立native用途、signal和Host会话；不能复用普通、保留读取或恢复写入token。目的会话关联保留读取token及workspace版本，工作区撤权、关闭源选择和Host关闭同步发撤权信号。
2. Host缓存PreparedRetentionExport。它同时持有源和目的租约；替换预览、停止或导航时先销毁未派发缓存，再等待排空，最后释放native目录权限，避免等待自己的缓存造成死锁。派发中的准备结果由worker拥有。
3. API只投影元数据，不把base64原件内容或内部暂存名暴露给Dart/模型。确认只接受当前缓存的export ID与digest；旧、跨scope、过期及重复请求拒绝。发布结果丢失只查询持久回执并严格匹配ID/digest。
4. 页面明确显示目的目录、文件名、所选版本及是否已变化、包大小和摘要。数据包包含可直接解码的文件内容，base64不是加密。目标名称仅单个文件名并以.orange-retained.json结尾；无法覆盖已有目标。
5. 重开后需要内容无关的导出记录发现入口，不能仅依赖内存export ID。当前Runtime只有按ID查询；接线时补上有界owner/Run/operation索引及权限/分页测试，再固定升级消费者。unknown记录不当作成功，也不根据目标文件存在自动补成功回执。
6. 新增UI竞争/撤权/缓存销毁/回复丢失测试和实际macOS/FRB目标写入测试。覆盖源不变、排他发布、目录身份、暂存后取消、写入后回执失败、重开、离线包校验；选择器/模型替身明确标注。原生测试结束必须恢复默认App，检查实际0GGUF及匹配组件。
7. unknown导出暂存/最终文件的明确检查和清理，以及原件删除/额度释放，另有独立授权与持久回收方案。成功导出不等于删除授权。

生产者详细实现与测试见server候选docs/retained-export-preparation.md；统一证据见services_plan/execution/retention-export-staging.json。主线仍是Runtimea2cdafb/schema17，候选未合并。
