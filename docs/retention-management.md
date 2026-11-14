# 保留原件管理：接线进度

当前候选固定消费服务端 Runtime `a2cdafb95fab90bc1ded82d4a4c061be40463d35`（schema17）。归档和来源摘要见 `config/runtime.lock.json`；普通构建不读取相邻仓库。共享包的248项测试以及195项Runtime测试通过。新增能力只用于可信宿主，不增加模型工具。

## 已接入的桌面接口

- `list_retained_edits(handle, run_id, before, limit)`：返回当前本地用户的操作ID，包含成功发布、已独立解决的unknown以及已经归档的记录。每页1—100，before为严格字典序上界。没有路径、内容或文件摘要。
- `inspect_retention_outcome(handle, run_id, operation_id)`：返回已提交的归档review ID或None。用于丢失批准回复后的查询，不恢复文件权限、不重发批准。

两者通过现有单Host Actor访问Journal，不调用恢复普通执行授权的run_context。不支持文件编辑的目标系统明确返回 `EDITING_UNAVAILABLE_ON_TARGET`。错误Run、无效分页和过期Host按既有错误边界拒绝。Rust/Dart接口由固定FRB版本成对生成并检查公开接口清单。

宿主测试使用真实临时文件、SQLite和受控模型协议替身：实际编辑后注入回执失败→unknown不进入保留索引→独立恢复确认→关闭选择后发现ID→测试内部独立选择与精确批准归档→关闭scope后查询已提交review ID。测试内部选择不代表实际native系统选择器或产品归档UI已实现。

## 下一步接线

1. 为Runtime `PatchRetentionGrant`建立独立用途的native选择和Host会话，不能复用普通工作区或恢复写入token。新选择绑定workspace版本，关闭/撤权先发信号、后排空、最后释放系统scope；Host重开不能复用。
2. 提供实际保留文件观察和预留额度投影；持有receipt直到投影结束，展示前复查撤权。禁止把受保护原件文件名或路径直接暴露给模型。
3. 以单独页面显示“原地保留”和预留额度。明确归档不会释放物理磁盘空间，原件仍可能被外部旧描述符修改。256MiB/1000条为已有归档准入限制，不是磁盘配额。
4. 归档必须预览当前原件并明确确认精确摘要。晚到或撤权结果不恢复界面；丢失回复只查询review ID，不自动重发。
5. 原生集成测试覆盖成功、修改后拒绝、撤权、迟到选择、重复确认、重开和丢失回复。默认app最终恢复为 `lib/main.dart`，严格验证固定组件与实际零GGUF。
6. 导出和删除另行实现独立权限、精确批准及故障恢复；目前没有这两种能力。不能自动删除以解除unknown或释放额度。

以上1—6仍未完成，不把元数据查询接口或Runtime单元测试计为完整桌面保留管理完成。当前主线仍为1074e1c/Runtimef0474a4，新候选尚未合并。
