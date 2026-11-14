# 导出文件保留区：桌面实现

当前固定消费服务端 Runtime 48a7aae275c2467ef865a9301135945a889d7f2d/schema21；移入保留区最初由e77a61e/schema20引入。源码从校验过的独立归档显式导入；普通构建不访问相邻服务端源码。当前固定共享包包含210项Runtime测试，迁移已用实际schema19 CLI数据验证。

## 产品流程和接口

在导出记录中打开独立目的目录检查，然后选择“选择目录并预览移出目标”或暂存。系统选择器单独说明写权限；检查权限不会自动升级。匹配有效数据包且原应用写入者已停止时，显示目录、文件、字节数、SHA-256与批准摘要。用户点击“确认移入保留区”才派发。

| FRB接口 | 输入及结果 | 保证 |
| --- | --- | --- |
| authorize_export_retirement | Host句柄、读会话、独立选择ID、绝对目录；返回ExportRetirementAccessView | 原物理目的目录、当前读权限和独立写选择一致；至多32个会话 |
| prepare_export_retirement | 写会话、幂等请求ID、target/staged；返回ExportRetirementReviewView | 实际对象检查，持有写入者锁/读写租约；五分钟精确预览；没有文件移出效果 |
| approve_export_retirement | 写会话、retirement_id、expected_digest；返回ExportRetirementOutcomeView | 消耗缓存准备对象；不匹配拒绝；派发前写入SQLite；失败不自动重试 |
| list_export_retirements | 原运行、操作、导出ID、可选before、limit | 本地所有者元数据查询，1—100条；界面每页50条；不恢复文件权限 |
| inspect_export_retirement | 独立读会话、retirement_id；返回ExportRetirementInspectionView | 核对绑定目录与标记后实际读取item状态；不修复历史结果 |
| suspend_export_retirement | 写选择ID | 同步撤权信号先于排队清理；丢弃缓存证明后排空，完成后才释放系统目录授权 |

读权限关闭也会撤销相关写会话并先丢弃缓存证明，避免读租约自等待。Host结束信号覆盖新写会话。其他恢复、导出、保留原件会话不能复用此选择ID。普通模型工具没有这组接口。

## 持久性与故障表现

结果状态为prepared、dispatching、retained、unknown。retained表示当次捕获收据成立，不保证文件以后不被其他程序改变。回应丢失或错误摘要都不会自动再次批准；界面查询持久记录并提供保留区检查。批准尝试后清除旧目的检查快照，避免继续把移动前状态展示成当前状态。

重启后只通过元数据查回记录，再以新目的目录读选择核对保留项。不存在绑定时显示“不能判断是否发生过移出”，不是“没有效果”。unknown即使当前内容匹配也保持待核对。

保留目录不是系统回收站。内容仍占空间，原件归档/预算不改变；当前恢复副本能力见[恢复副本](export-restoration.md)；没有永久删除、自动清理或SLA声明。外部进程最后时刻替换名称时，替代对象保留并返回unknown；不宣称全局对象CAS或排除外部旧句柄写入。用户界面明确说明当前恢复能力限制。

## 验证方式

`scripts/check-export-retirement.py`依次执行固定源和FRB清单、Rust/Clippy、Dart格式/静态检查、组件测试及签名macOS应用集成测试。在临时目录中实际编辑、导出、移入保留区、核对字节、关闭/重开Host及重新检查；显式替身仅用于模型响应和系统选择器回调。保留原导出与只读检查断言，再增加新场景。结束后必须以`scripts/check-flutter.py`恢复默认lib/main.dart，并检查严格签名、当前Runtime及实际0个GGUF。

统一台账记录每次失败/修正和最终结果。没有手动系统选择器、其他OS、永久删除、空间回收或真实模型推理的新增认证。
