# 桌面现有文件编辑（候选实现）

## 来源与线程边界

本候选固定消费 Runtime `766ff0db8324c49539d8f2005b12434d09ff324c`；归档、清单及来源摘要见 `config/runtime.lock.json`。普通构建只使用本仓库固定 vendor，不读取相邻服务端源码。5 个共享 package 包括 E03 内部的 platform-files；不增加核心工程。消费者 Cargo.lock 的包身份未改变。

独立 OS 线程仍独占 HostRegistry 和 Journal；Tokio 的两个 worker 支持发布阻塞通道之外的撤权、取消和 I/O，不让多线程并发访问 SQLite。

## 权限与接口

读取、新建、编辑是三份独立授权。native 选择器分别取得 scope，释放时校验用途。编辑必须属于当前读取工作区；切换工作区、选择 token、权限版本或关闭 Host 时，旧预览及选择立即失效。重开不会自动恢复 OS 权限。

- `authorizeEditingAccess` / `listEditingAccess`：登记或查询独立编辑选择，携带 consent、workspace、version 与 session token。
- `suspendEditingSelection`：按精确 session token 停止；迟到的旧选择回调不能关闭或恢复新 scope。
- `revokeEditingAccess`：按权限版本撤权；先发队列外信号，排空操作，再释放 native scope。
- `startEditingRun`：显式传入编辑权限选择，可另传独立的新建权限。UI 默认关闭编辑，不从普通 Run 自动升级。
- `previewEditingTool`：由 Rust 基于真实文件计算 diff、参数摘要和 preview digest。Dart 不从模型 patch 生成可信批准内容。
- `approveEditingTool`：提交精确 preview digest。普通工具批准入口不能批准 patch；错操作、晚到预览及已失效选择均拒绝。

每个 Run 使用独立的可撤销编辑句柄。取消一个已经提交提案但尚无效果的 Run 不撤销同 scope 下另一个 Run；执行状态不明时仍隔离工作区，不能以新授权绕过恢复门槛。撤销整个编辑权限会停止其绑定 Run，但不误伤独立只读 Run。

当前实际发布后端仅 macOS；其他目标由 Host 明确返回不可用，不把空实现展示成成功。创建、删除、重命名及任意命令不是本编辑工具的权限。

## 安全属性与失败处理

首次真实 native 测试发现沙盒暂存文件的 quarantine 时间戳不同，原文件未变、操作进入 unknown。证据保留在统一执行目录，断言没有删除。Runtime81bf2d9 保留系统生成的较新时间戳，其他安全标记、隔离应用、事件标识、ACL、owner/group/mode/flags 及扩展属性仍精确比较。返回和持久化的是目标真实完整快照，后续检查不忽略时间戳。原文件完整快照必须未变。

严格元数据复制 API 未改变。新增、移除或未知格式标签仍拒绝，因此某些外部来源文件尚不支持编辑；没有覆盖所有 macOS 文件。不会移除 quarantine，也不会绕过系统拒绝。source SHA、参数、实际预览、权限版本和发布前重验共同约束效果。unknown 不自动重放。

捕获旧文件到发布新文件之间仍存在命名空间缺口；当前后端不能称为全局原子内容 CAS。手动恢复、保留原件管理、全部文件系统与跨 OS 行为尚需完成产品级验收。

## 验证状态

旧 Runtime216ca3d 的9项 Rust 宿主测试、严格 Clippy、21个组件测试与静态分析通过；原生6场景中5通过、编辑效果场景失败。独立签名沙盒探针已验证上述修复，服务端189 Runtime、7元数据测试与240共享制品测试通过。

新固定版本的成对 FRB 已重新生成；模型组件清单为 `716511eb6796e1b2e3a19cc86682ab1ad2d84e53194d158418f684d5228c88f6`，开发签名、CPU、最低 macOS27.2、无测试权重。新固定版本完整桌面回归已通过：9项 Rust、严格 Clippy、21个组件测试、6项 macOS 原生场景，包含真实精确编辑和撤权排空。日志 desktop-edit-native-fixed.log，验证会话94984 exit0。实际固定0.5B托管模型的2项测试也通过：导入/启动/35秒空闲心跳、批准后真实读取与搜索、删除源后清除上下文、停止与Host关闭清理。默认 lib/main.dart 开发包已恢复，严格签名和嵌入组件校验通过，实际包内0个GGUF。日志 desktop-edit-managed-model.log 和 desktop-edit-default-restoration.log，分别18107/21333 exit0。

native 测试的模型 HTTP 和选择器回调是明确夹具；实际 Rust/FRB、SQLite、沙盒文件效果是真实运行。组件测试证明状态和交互，不能证明 OS 选择器或真实推理。已有服务端7B精确编辑证据属于上一固定 Runtime 的单次任务，不等于新版本全面模型准入、桌面实际7B流程或 GPU 认证。

## 后续恢复索引增量（未合并主线）

新增 `listUnresolvedEdits(handle, runId, before, limit)`。它只列出当前拥有者、指定Run下仍未解决的patch操作ID；limit为1—100，before为严格字典序上界。不打开工作区、不恢复原读取/编辑权限、不批准恢复、不重发模型或工具。其他目标明确返回不可用。取消Run后的不确定效果仍可由拥有者发现。

当前候选固定Runtime4ab8c19的9项Rust测试、严格Clippy、21组件和静态检查通过；实际原生6场景通过，并新增了“释放读取权限后可查询元数据、但内容读取仍拒绝”的FRB验收。日志edit-recovery-desktop-check.log和edit-recovery-desktop-native.log，82309/80582 exit0。新的组件清单为cb4f0d4c870c91d9cc6687e25854ed9d72f9a747f05c94cd29a4ed4e7fb5f56d，无测试权重。

上文真实0.5B/7B证据和默认包证据属于Runtime81bf2d9整合阶段，不冒充本增量的真实推理证据。此增量没有恢复授权/文件检查/决策批准界面；原生测试仅证明元数据入口不会恢复文件权限，并不代表完整恢复流程已完成。本候选默认App需在原生测试后独立恢复。

当前恢复读取界面与隔离边界见 [recovery-inspection.md](recovery-inspection.md)。上节4ab8c19描述保留为索引阶段历史证据；新766ff0d读取检查已通过实际原生回执故障测试，恢复写入UI仍未实现。
