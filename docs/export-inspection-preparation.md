# 独立导出检查：桌面接线入口

已固定导入Runtime 84d797ca3f2eefdfd675e5d905664add292b713a/schema18。254项共享测试（含201Runtime）及消费端9Rust/Clippy/static/52组件测试通过；成对FRB仍未新增检查接口，当前没有检查按钮或清理能力。

匹配组件c0767f7527ba621e2f41c307bfcdcaba36b7f650dda736ec67a0c9c4fa82c1e0，无测试权重。尚未验证这个Runtime的实际签名检查UI或默认App；旧候选默认包不作为新版本证据。

## 接口和接线

1. 从已有导出记录列表选定export ID，独立选择该次导出的目标目录。Runtime authorize_export_inspection(owner,run,operation,export_id,root)只校验目的物理目录与记录，不依赖源目录Grant。源已撤权或移除也不恢复源权限。
2. 建立独立native用途、信号和Host会话，不能复用源保留、导出写入、恢复或普通workspace token。Host关闭和独立结束检查立即撤权，再等待receipt排空后释放native scope。导航或迟到结果不能重新展示旧文件状态。
3. inspect_export_files返回ExportInspectionReceipt。投影时持有receipt并在返回前再次检查。DTO仅包括当前文件存在性/大小/摘要/匹配及有效包标记、导出ID/已存状态和用户目标文件名。不返回原源路径、内容、内部暂存名或WorkspaceGrant。
4. 页面分别显示记录状态、当前目标和当前暂存。“匹配已批准的数据包”不等于“有成功回执”；unknown保持unknown，不自动发布、确认成功或删除。成功回执也不会因当前文件被外部修改而从历史消失。
5. 扩展既有token冲突检查并验证独立性、错目录/owner/Run、过期Host、迟到选择、撤权/排空、源权限不恢复和重开。加入实际签名macOS/FRB检查测试，模型/选择器回调替身如实注明。最后恢复默认App并验证来源与实际0GGUF。
6. 清理/删除必须另有写入授权和精确批准。在开放前处理旧export worker仍可能写入的证据及命名空间并发变化；静态检查快照不是writer停止证明，更不是删除授权。当前不释放归档额度、不清理未知文件。

详细Runtime边界与证据见server docs/export-inspection-preparation.md和统一执行台账export-inspection-staging.json。主线仍是c067a3e的导出实现；这个只读检查候选未合并。
