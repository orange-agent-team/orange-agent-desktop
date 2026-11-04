# 本地 Agent 执行接口与验证边界

2026-11-05。此切片实现 Rust Host 和生成的 Flutter/FRB 接口。模型安装、应用内聊天/批准界面、打包模型服务与 App Sandbox 模型传输尚未完成，不据此标记完整桌面 Agent 完成。

## 所有权与并发

一个专用线程持有一个 SQLite Journal 和 current-thread Tokio runtime；有界队列最多等待 32 个任务，超限返回 `HOST_BUSY`。公开会话注册表只用于查找不透明句柄和投递任务，不在模型网络等待期间持锁。不通过第二个 SQLite 写者绕过独占锁，也不为 Journal 增加 unsafe Sync。

撤权与取消先通过注册表中的原子撤销标记/watch 通道打断当前执行，再排队提交持久状态。取消某个 Run 使用独立的 Run grant，不撤销整个工作区的用户同意。工作区撤权使用共享 WorkspaceRevoker，覆盖所有关联 Run。成功响应代表对应持久操作已提交；信号发出本身不是持久撤权确认。

关闭 Host 立即作废句柄并广播取消；晚到的响应不能再返回内容。所有者线程退出时关闭 Journal 并释放锁。立即重开遇到旧所有者尚未排空时返回 `HOST_BUSY`，调用者可有界重试。关闭不表示 GPU、Job 或外部模型进程已回收。线程退出/异常同样作废会话并触发撤销信号。

## FRB 接口

全部命令要求当前 `handle`，失败只返回安全错误码和关联 ID。目录路径及模型配置只能由可信 UI/模型管理层提供，不能接受模型输出作为权限。

| 接口 | 输入与结果 | 关键约束 |
| --- | --- | --- |
| `connectLocalModel` | 私有服务目录 → ModelConnectionView | 目录必须在 Host 私有存储内；验证 profile/process/api.key 的文件类型、权限、大小与一致性，检查私有 socket 健康及实例未变 |
| `disconnectLocalModel` | handle → 空 | 清除连接，不声称停止外部模型服务 |
| `startRun` | workspaceId/requestId/prompt → AgentRunView | 本次会话目录访问已恢复、已配置模型；相同请求幂等，改变提示词或工作区返回冲突 |
| `inspectRun` | runId → AgentRunView | 所有者、当前 grant 及已读取源数据必须重新授权；源删除/变化不展示缓存最终答案 |
| `approveTool` | runId/operationId/expectedDigest → AgentRunView | 比对不可变操作和参数摘要；批准期限至多 60 秒且不超过 Run 截止时间；不由 advance 自动批准 |
| `advanceRun` | runId/expectedRevision → AgentRunView | 版本不匹配不执行；必须保持模型身份一致；执行后有内容时再次校验来源 |
| `cancelRun` | runId → AgentRunView | 只需有效句柄及所属 Run，不依赖仍可访问源目录；保留已完成历史但隐藏最终内容 |

AgentRunView 包含 run/workspace/model 身份、phase、revision、steps、invocations、待批准操作、finalText 和 failure。参数预览是 JSON 文本，不是授权请求的可修改副本。列表 `listRuns` 保持只含元数据，不能通过历史列表绕过来源校验。

当前每个 Host 会话最多保留 256 个 Run 上下文；单 Run 默认 30 步、20 次模型调用、每次最多 256 输出 token、15 分钟截止时间，提示词上限 64 KiB。这些是本地开发限额，不是计费认证。

`MODEL_NOT_CONFIGURED` 不创建占位 Run。`MODEL_CONTEXT_CHANGED` 阻止旧 Run 隐式切换模型。`TOOL_PREVIEW_CHANGED` 拒绝过期或被修改的参数预览。`RUN_SOURCE_UNAVAILABLE` 不退回原始未经授权的 Journal 视图。`WORKSPACE_RECOVERY_REQUIRED` 保留 unknown 调用隔离，取消不将未知调用变成可安全重放。

## 本地模型连接

当前只连接 CPU llama.cpp 私有 Unix socket，Windows 明确返回传输不可用。模型 ID 来自模型别名、上下文长度、模型文件及可执行文件摘要的规范化摘要。后端请求将内部身份映射为服务别名；后端只生成候选响应，不能执行工具。

连接显示 `local-development-configuration`：这是私有配置和健康检查，不是生产模型审批、二进制远程证明或生命周期所有权。外部服务的停止、崩溃回收、重启及 App Sandbox 集成仍需由独立模型管理工程完成。模型密钥不通过 FRB 返回，也不能放在用户授权工作区。

## 验证方式

`python3 scripts/check-bridge.py --native`：4 项 Rust 测试（其中一项覆盖整个 actor 并发与恢复流程）、Clippy、固定生成物、Dart 静态分析和真实 macOS Flutter/FRB/SQLite 集成。并发模型是明确替身，工具文件与数据库真实执行。原生测试新增了未配置模型拒绝、外部服务目录拒绝和连接清除接口调用，未将其写成真实模型 UI 验证。

`scripts/check-real-run.py` 是单独的真实模型验收，需要显式给出 `--model-lock`、`--build-manifest`、`--model`、`--backend`、`--model-host`。普通构建不搜索相邻仓库。驱动校验已存在模型与 CPU 后端摘要，创建隔离目录和唯一内容，启动私有服务并持续保活，调用 `run-acceptance` 示例完成批准、真实读取、最终内容匹配、重开不重放、删除源后拒绝及取消。结束时关闭父控制通道并验证服务 stopped。仅测试驱动批准自身 fixture 的 `proof.txt` 读取或根目录列举，产品代码没有自动批准入口。

真实结果保存在 `.local/real-run/last-report.json`，不保存模型密钥、用户目录内容或提示词。该结果证明桌面 Rust Host API 与真实 CPU 模型闭环，不能替代 Flutter 模型页面、App Sandbox socket 访问、正式签名、GPU、Windows/Linux 或计费验证。
