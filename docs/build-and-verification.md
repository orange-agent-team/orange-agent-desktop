# 桌面构建、固定依赖与验证

2026-11-05。先核对实际证据状态，再将本文件中的命令用于恢复；Mac构建不代替Windows首发认证。

## 固定版本

- Flutter `3.47.9`、Dart `3.13.7`、macOS ARM64 SDK，提交`c197ca5199e9ee5661e865596c9c07294dfab51c`。
- 官方archive：2,268,740,583字节，SHA-256 `6545b85938745dc5070e9faf2adf70233c1811009d87fe6d27bfcda5a04b7698`。来源为[Flutter官方归档](https://docs.flutter.dev/install/archive)使用的`flutter_infra_release/releases`桶路径。没有切换第三方镜像。
- FRB Rust/Dart/hooks/codegen `2.13.0`，cargo-expand `1.0.126`；Native Assets使用实际锁定的`native_toolchain_rust 1.0.4+0`。
- 桌面Rust固定为`1.98.1`，服务端共享源码验证仍是`1.97.1`；两个版本分别记录，不更改系统默认工具链。桌面原生加载与应用集成已实际通过，兼容修复见下文。

运行`python3 scripts/prepare-flutter.py install`验证archive大小/摘要、安全路径、解压大小、符号链接范围及Git提交，然后安装到本仓库`.local/toolchains`。状态命令为`python3 scripts/prepare-flutter.py status`。

生成器安装到`.local/tools/frb-2.13.0`与`.local/tools/cargo-expand-1.0.126`，使用官方crate固定版本和其锁定依赖。FRB codegen上游工具锁中的futures-util 0.3.29已被registry标记yanked，Cargo允许按原锁安装；这是生成工具依赖，桌面运行时实际锁定futures-util 0.3.34。完整供应链审计仍需在候选交付阶段完成，不隐瞒该警告。

`scripts/environment.py`只为任务子进程设置工具路径、项目PUB_CACHE和配置目录，不改HOME或系统默认Rust版本。Flutter及Dart工具统一设置`FLUTTER_SUPPRESS_ANALYTICS=true`、`DASH__SUPPRESS_ANALYTICS=true`，直接Dart命令再传`--suppress-analytics`；不通过修改用户全局遥测偏好绕过文件权限错误。

## 共享Runtime与生成物

普通构建首先运行`python3 scripts/import-runtime.py --verify`，只校验本仓库源码，不自动搜索相邻服务端目录。

升级时由维护者明确提供archive，运行`python3 scripts/import-runtime.py --archive PATH`。来源commit、archive字节/SHA、release manifest SHA和逐文件摘要必须匹配`config/runtime.lock.json`。路径穿越、链接、额外文件和任意篡改均拒绝；已有源码被修改时不会静默覆盖。

生成：`python3 scripts/generate-bridge.py`。静态/Rust验证：`python3 scripts/check-bridge.py`。真实Mac Flutter/FRB集成：`python3 scripts/check-bridge.py --native`。可用Mac工具链及普通开发app构建：`python3 scripts/check-flutter.py`。

Rust检查使用`--locked`，Dart使用`--enforce-lockfile`；hook也向Cargo传`--locked`。应用测试使用隔离临时目录，不访问真实用户工作区，不调用付费模型、不产生真实资金操作。

## 已定位的原生加载故障

Rust1.97.1下，实际Mac应用构建完成，但打包前cdylib及打包后framework的`LC_SYMTAB.stroff`均为2,592,412，不满足8字节对齐，dyld拒绝加载。该结果说明问题已经存在于打包前，不能只调整Flutter库路径或关闭系统加载校验。

[Rust上游问题157750](https://github.com/rust-lang/rust/issues/157750)和[修复158410](https://github.com/rust-lang/rust/pull/158410)记录了Mach-O字符串池对齐修复，后者进入1.98.0里程碑。选择补丁版[1.98.1](https://blog.rust-lang.org/releases/1.98.1/)以同时包含该系列修复和1.98.0的vtable修正。清理项目构建缓存后实际重建，stroff为2,609,656，满足8字节对齐，独立dlopen和真实Flutter/FRB集成均通过；没有修改二进制或绕过系统校验。

另有Xcode CoreDevice系统插件版本警告，但这次没有阻止app编译。当前没有改动或替换系统私有框架，也没有跳过dyld校验。

## 当前认证边界

SDK摘要/提交/版本实际通过；固定f5b3644共享Runtime包的63项Rust测试和篡改拒绝通过；E05的4项Rust测试、Clippy和Dart analyze通过。真实打包Flutter/FRB/SQLite流程验证了授权、重启后sessionAccess=false、显式恢复、撤销和私有根拒绝；按钮测试中的系统选择回调是明确替身，业务Rust/SQLite是真实执行。

另通过计算机使用工具观察到实际NSOpenPanel打开、用户完成目录选择、应用显示只读授权；没有读取用户目录文件内容，也未撤销用户已选择的目录。GUI撤销没有手工完成，使用隔离目录的自动化按钮流程验证。观察记录位于`.local/ui-tests/workspace-ui-observation.json`，不保存系统文件列表。

普通macOS ARM64开发app及产物摘要位于`.local/build-evidence/flutter-macos.json`。自动将窗口置前仍有系统返回警告，因此不把后台集成测试当作完整交互/可访问性认证。

当前证明Host/工作区元数据、私有SQLite、类型与句柄及上述只读授权流程。真实桌面Rust Host API另已完成CPU模型→显式批准→文件工具→最终答案→重开与删除源拒绝，详情见[本地Agent接口](local-agent-api.md)。完整Agent UI、云身份、App Sandbox模型传输、OS安全书签、GPU、Windows/Linux实机、正式签名和公证仍需分别完成。

本次固定源码包为f5b364410c3f8f48471c67111fb6da5afdc4a144，96158字节，归档SHA-256为20c7819d59cea316b53edc2d6a02efbadd92ca17bbda38d4f45ab6f279f262f5。已通过重建、独立导入和篡改拒绝；旧vendor目录从工作树移除，可通过Git历史回退。本次还增加了串行Host执行器、即时取消/撤权信号、Run/批准/推进/取消及本地模型连接接口，并通过生成的FRB边界调用；聊天、模型管理或工具批准界面仍待实现。
