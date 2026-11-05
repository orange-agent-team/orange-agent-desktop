# Orange Agent Desktop

日期：2026-11-05。当前仓库职责为E05 `orange-desktop-bridge`和E06 `orange_desktop`，共2个工程。E03 Agent Runtime源码按用户确认移入服务端仓库，桌面通过固定提交/不可变版本引用同一共享核心。

Flutter负责会话、工具批准、成果、模型/Worker、钱包团队等交互；FRB桥接与Dart同包配对。桌面本地Run使用SQLite，云Web Agent由平台隔离工作区执行；两者的运行历史、凭证和文件不自动互相同步。

平台Admin Panel位于独立网页入口，不嵌入桌面或向模型开放管理权限。桌面组织owner/admin仍是租户角色，不等同于平台管理员。用户本机GPU经Broker许可与受管监督器执行，服务端仓库归属不强制任务上云。

本地Git已初始化。E05位于`crates/desktop-bridge`，E06位于`apps/desktop`；已实现私有本地记录、Host句柄、规范金额、只读工作区选择/授权/撤销和Run状态查询。重启后保留授权记录，但须重新选择目录开放本次访问。应用已有单次Run和只读工具批准界面；模型安装/进程管理、完整多轮会话与云身份仍待实现。

Rust Host及生成的FRB接口另已实现Run创建/查看/批准/推进/取消和私有本地模型连接。实际CPU模型验收通过批准、真实文件读取、恢复不重放和删除源拒绝；另以明确模型协议替身验证了真实沙箱Flutter批准界面、FRB、私有Unix IPC与文件工具；打包模型服务和真实模型UI闭环仍待验证，详见[本地Agent接口与验证](docs/local-agent-api.md)。测试示例和模型验收驱动不是额外产品工程。

共享内核来自服务端固定提交的可校验源码包，存放在本仓库`vendor/runtime-ddc3151`。普通构建校验实际Cargo依赖路径和源码摘要，不读取相邻服务端目录。参见[架构与边界](docs/architecture.md)、[构建和验证](docs/build-and-verification.md)。实际原生测试和目标平台认证以执行台账为准。
