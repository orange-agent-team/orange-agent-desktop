# macOS 桌面 Release 开发包

在 macOS arm64 服务环境准备好仓库固定的 Flutter、Rust、pub 缓存及审核过的模型服务组件后，执行 `python3.12 scripts/package-desktop-release.py`。构建机需要支持 APFS 文件克隆，私有模型缓存与真实用户数据单独管理。构建器从本仓库一个完整 Git 提交解包到两个不同的干净目录，核验受管 Runtime，分别执行离线 pub 安装与 Flutter Release 构建。

当前 Rust 桥接目标是 aarch64-apple-darwin。构建只为子进程启用 FLUTTER_MACOS_ARM64_ONLY，使目标与工具链锁一致。桥接库在链接时就采用最终框架安装名。Xcode 的 Release 阶段剥离本机调试对象路径并在外层签名前完成资源嵌入。沙箱、用户选定文件读写和网络客户端权限保留，打包验收会拒绝带有 get-task-allow 的 Release。

归档放在 `.local/desktop-distributions/`，文件名包含内容摘要。核对旁附 JSON 的 SHA-256，将包解压到自选目录。可在该目录运行只读安装自检。

```sh
orange_desktop.app/Contents/MacOS/orange_desktop --verify-installation
```

自检在 Flutter 引擎及用户工作区初始化前从应用自身的 Frameworks 装入 Rust 库，读取公开 FRB 内容哈希后退出。发行脚本核对这个值与固定 Dart 绑定一致，并对解包前后应用执行 codesign --verify --deep --strict。两次归档逐字节相符才保留成功记录。失败时会记录有差异的文件，原应用包及签名维持实际构建结果。

本包使用本机开发签名。当前验收平台为 macOS 27.2.1 arm64，应用和内置模型后端分别声明最低系统版本，启动模型前还需满足后端要求。开发包不包含权重。公证、Developer ID 分发和其他操作系统另行验收。
