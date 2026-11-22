# Orange Agent Desktop

会话的“运行模板”支持内置模板和本地 JSON 包。点击“安装本地模板”，粘贴清单，核对完整指令、只读工具与 SHA-256，再确认安装。选中版本后可单独启用、停用或卸载。切换和卸载会撤销旧会话的续跑权限。当前桌面实现使用服务端提交 `938bc63` 的独立源码包。

本地会话支持按任务选择记忆空间、逐次批准工具请求、重启后恢复记忆草稿，以及在正文无法读取时由所有者按标识清理条目。[记忆管理界面](docs/memory-manager-ui.md) · [任务授权与验证命令](docs/task-memory.md)

本仓库负责E05 `orange-desktop-bridge`和E06 `orange_desktop`，共2个工程。E03 Agent Runtime源码按用户确认移入服务端仓库，桌面通过固定提交/不可变版本引用同一共享核心。

Flutter负责会话、工具批准、成果、模型/Worker、钱包团队等交互；FRB桥接与Dart同包配对。桌面本地Run使用SQLite，云Web Agent由平台隔离工作区执行；两者的运行历史、凭证和文件不自动互相同步。

平台Admin Panel位于独立网页入口，不嵌入桌面或向模型开放管理权限。桌面组织owner/admin仍是租户角色，不等同于平台管理员。用户本机GPU经Broker许可与受管监督器执行，服务端仓库归属不强制任务上云。

本地Git已初始化。E05位于`crates/desktop-bridge`，E06位于`apps/desktop`；已实现私有本地记录、Host句柄、规范金额、只读工作区选择/授权/撤销和Run状态查询。重启后保留授权记录，但须重新选择目录开放本次访问。应用已有单次Run、只读工具批准和固定本地模型的导入/启动/停止；完整多轮会话、完整恢复治理与云身份仍待实现。

Rust Host及生成的FRB接口另已实现Run创建/查看/批准/推进/取消和私有本地模型连接。实际CPU模型验收通过批准、真实文件读取、恢复不重放和删除源拒绝；另以明确模型协议替身验证了真实沙箱Flutter批准界面、FRB、私有Unix IPC与文件工具；旧版打包模型服务与真实模型UI闭环已有证据；本次Runtime升级的实际模型和包装回归另行记录，详见[本地Agent接口与验证](docs/local-agent-api.md)。测试示例和模型验收驱动不是额外产品工程。

共享内核来自服务端固定提交的可校验源码包，当前目录及完整提交记录在 [Runtime 锁定文件](config/runtime.lock.json)。普通构建校验实际Cargo依赖路径和源码摘要，不读取相邻服务端目录。参见[架构与边界](docs/architecture.md)、[构建和验证](docs/build-and-verification.md)。实际原生测试和目标平台认证以执行台账为准。

模型组件可由明确artifact生成开发包；当前已验证真实沙箱子程序启动与错误父认证拒绝，完整权重也已通过Rust私有缓存导入及推理验收。固定CPU模型的安装界面与受管启动/停止已接入，其他模型/OS与孤儿恢复仍待实现，见[模型组件打包](docs/model-service-packaging.md)。

固定本地模型受管接口、所有权与真实原生验收见[受管模型服务](docs/managed-model-service.md)。

新会话可以显式选择“允许任务询问补充信息”，通过独立问答状态接收1—3个问题。答复不能批准文件工具，停止访问和取消会关闭等待中的问题。该功能在历史 Runtime 53ed515 上已通过95项共享Rust、8项Bridge、14项组件及3项实际原生测试。模型/系统选择回调的替身证据与真实模型证据分开，完整产品仍未完成，详见[用户问答](docs/user-questions.md)。

历史 Runtime 6b6c08b，修复规范化不敏感文件系统上的Unicode受保护路径别名。旧版目录仅保留历史对照；当前桌面新增用例与正式验证状态见执行台账及[构建文档](docs/build-and-verification.md)。

文件创建集成候选现已包含独立目录同意、默认关闭的会话写入能力、完整新文件提案与逐次批准。参见[创建权限与恢复边界](docs/file-creation.md)。9项Rust宿主、严格Clippy、17项组件及5项原生测试通过；默认无权重开发制品已校验，实际系统目录选择器因电脑操作通道故障尚未验证；不能视为生产认证或完整工具范围。

工具契约快照候选固定Runtime97fdddb；输入/输出schema、工具版本与审批契约在派发和恢复时检查。真实旧Runtime到schema7的CLI恢复、真实7B创建场景及5项原生消费者场景已有证据。托管模型完整验收和默认无权重包恢复已通过；并发执行器、插件处理器和完整工具范围未因此完成。参见[工具契约与升级](docs/tool-contract-upgrade.md)。

隐私与预算体验的产品验收材料包括[数据去向与授权](docs/privacy-budget/01-data-decisions.md)、[报价确认稿](docs/privacy-budget/02-quote-confirmation.md)、[缺资源状态稿](docs/privacy-budget/03-resource-fallback.md)和[场景走查](docs/privacy-budget/04-scenario-review.md)。
