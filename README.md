# Orange Agent Desktop

日期：2026-11-04。当前仓库职责为E05 `orange-desktop-bridge`和E06 `orange_desktop`，共2个工程。E03 Agent Runtime源码按用户确认移入服务端仓库，桌面通过固定提交/不可变版本引用同一共享核心。

Flutter负责会话、工具批准、成果、模型/Worker、钱包团队等交互；FRB桥接与Dart同包配对。桌面本地Run使用SQLite，云Web Agent由平台隔离工作区执行；两者的运行历史、凭证和文件不自动互相同步。

平台Admin Panel位于独立网页入口，不嵌入桌面或向模型开放管理权限。桌面组织owner/admin仍是租户角色，不等同于平台管理员。用户本机GPU经Broker许可与受管监督器执行，服务端仓库归属不强制任务上云。

本地Git已初始化。E05位于`crates/desktop-bridge`，E06位于`apps/desktop`；已实现私有本地记录初始化、不可猜测Host句柄、旧句柄拒绝和规范金额字符串验证。应用目前明确显示为开发预览，会话执行、模型管理、工作区授权与云身份尚未接入，不能视作完整桌面Agent。

共享内核来自服务端固定提交的可校验源码包，存放在本仓库`vendor/runtime-628cd5f`。普通构建不读取相邻服务端目录。参见[架构与边界](docs/architecture.md)、[构建和验证](docs/build-and-verification.md)。实际原生测试和目标平台认证以执行台账为准，不能以生成了平台目录认定通过。
