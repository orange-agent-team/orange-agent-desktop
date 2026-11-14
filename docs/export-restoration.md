# 桌面保留区恢复副本

固定消费Runtime 48a7aae275c2467ef865a9301135945a889d7f2d/schema21。共享源导出263项测试（210 Runtime）及schema20实际旧CLI迁移通过。此候选的桌面验证状态以统一执行台账export-restoration-staging.json为准，不以文档描述替代验收。

## 交互

从导出记录的独立目的目录检查进入保留区记录，点击“恢复副本”。先输入新的 `.orange-retained.json` 文件名，再独立选择相同目的目录。实际保留项有效、内容匹配且目标空缺时生成五分钟预览，展示目标名、字节数、SHA-256和批准摘要。点击“确认创建恢复副本”才执行。

副本是完整导出数据包，不自动解包或授予Agent原工作区权限。保留区原件始终保留。已有文件/链接/目录不覆盖；空间和归档额度不释放。原导出或移出记录的unknown状态不会因副本成功而改变。

## 类型接口和信任边界

| FRB接口 | 输入 | 返回与拒绝条件 |
| --- | --- | --- |
| authorize_export_restoration | Host、读会话、独立选择ID、绝对目录 | ExportRestorationAccessView；绑定原物理目录，不能复用检查/移出/导出等选择ID |
| prepare_export_restoration | 写会话、请求ID、retirement_id、file_name | ExportRestorationReviewView；目标空缺、精确源对象、五分钟有效期；缓存不可序列化Runtime准备对象 |
| approve_export_restoration | 写会话、restoration_id、expected_digest | ExportRestorationOutcomeView；消费缓存准备对象，不匹配或过期拒绝 |
| list_export_restorations | 原运行、操作、retirement_id、before、limit | 本地所有者绑定的元数据列表；UI每页50，Runtime最多100；不恢复目录授权 |
| inspect_export_restoration | 新读会话、restoration_id | ExportRestorationInspectionView；当前目标与暂存状态，不修复历史收据 |
| suspend_export_restoration | 写选择ID | 同步撤权后排队清理，丢弃缓存读写租约后排空，最后释放系统目录选择 |

恢复拥有独立的类型、Host会话表和撤权信号。关闭父检查会话时同步撤销恢复与移出权限，分别丢弃缓存证明再排空读权限；Host终止同样覆盖这些会话。最多32个恢复会话，Runtime每所有者最多1000条持久恢复记录。

模型工具没有这些Host管理命令。仅已验证Apple目标启用本机路径；其他平台明确返回不可用。FRB仅传递审查过的DTO，不暴露Rust文件句柄、Grant或Prepared对象。

## 故障与恢复

Runtime先记录dispatching，再写独占0600暂存文件、fsync，以NOREPLACE发布目标，最后验证并提交回执。回应丢失、回执提交失败、撤权或文件变化都不得重放批准。界面立即丢弃预览，查询持久记录，允许独立检查目标/暂存。匹配文件仍可对应unknown。

UI使用操作代次丢弃迟到的选择器/批准回应。原生目录释放失败保留待释放ID以便重试，不报假成功。修改文件名会取消当前界面预览；再次准备前先释放上一写会话。移出和恢复之间切换会先释放上一缓存授权，避免保留写入者证明而自阻塞。

本次能力没有永久删除、自动清理暂存、物理空间回收、旧文件系统全局CAS或其他进程排他保证。恢复后其他进程仍可改变目标或保留项，回执仅证明当次已验证结果。

## 验证入口

`scripts/check-export-restoration.py`包含现有导出/独立检查/移入保留区验收，再增加实际副本字节、独立批准、目标占用拒绝、真实SQLite回执故障、重开后的成功与unknown记录及新读检查。模型响应和系统选择器回调明确是替身；实际Rust/FRB/SQLite/临时文件与签名macOS应用路径是真实的。

Rust测试还覆盖目的授权类型隔离、错误摘要、缓存证明关闭排空和无重复批准。组件测试覆盖精确文件名、错误父记录、迟到回调、错误/丢失回执、父控制器关闭和系统释放重试。原生测试后必须运行check-flutter.py恢复默认lib/main.dart，核对严格开发签名、固定Runtime和实际0个GGUF。没有生产签名、公证或人工选择器认证。
