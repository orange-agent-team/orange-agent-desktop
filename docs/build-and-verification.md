# 桌面构建、固定依赖与验证

## 2026-11-08 当前升级

当前固定共享源码为6b6c08bd23a5f186508d360815dec50f30c502c9，归档129606字节，SHA-256为489279f015d529950f5a2426fdc1e71d891aef6449870f9c24bacda076c1e2f1，独立共享工作区99项Rust用例通过。旧vendor目录保留用于历史对照；已知路径保护缺陷使旧版本不能作为当前安全回退方案。实际Cargo依赖只指向runtime-6b6c08b。新客户端锁中没有旧客户端锁与固定Runtime锁之外的包版本、来源或摘要。

已通过Rust Bridge6测试（同一actor案例新增3种搜索源删除/完整版本变更检查）、10个Flutter组件、成对FRB生成及2个实际macOS/FFI案例。受管模型UI实测完成真实read_file后连续search_text、精确提示词/参数批准、结果匹配及删除后清屏。完整生命周期套件、受影响源码绑定回归以及测试包恢复为默认无权重app的严格签名构建均通过，台账576单元/56 DONE/520 PENDING，无失效证据；整个G0—G6仍未完成。

原生验收保持精确Runtime提交及恰好4个只读工具断言。原断言仍引用旧提交/2工具时的失败已保留。连续输入曾因测试绑定保留焦点但输入连接已关闭而提交旧提示词；测试现在等待可编辑，重新点击限定TextField并断言全文后提交，没有直接改控制器文本伪造输入。诊断仅保留测试自建数据，确认模型停止后才清理。

另修复了测试权重恢复后增量构建沿用旧外层资源签名的问题。Flutter与模型嵌入步骤显式声明依赖，资源标记绑定框架和模型清单摘要；保留严格deep签名验证。完整切换路径已通过，默认app不含test-model.gguf，沙箱及用户选择文件只读权限未扩大。

下方是历史验证记录，旧提交、旧测试数量和旧目录操作描述不代表本次版本。

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

## 当前验证边界

本轮固定Runtime导出通过95项Rust测试；桌面8项Rust/SQLite测试、严格Clippy、Dart analyze、14项组件测试和3项实际Mac Flutter/FRB集成通过。原生测试覆盖普通读取与显式问答两条路径：问题回答提交后仍必须单独批准文件读取，删除已读来源后不能继续显示内容。模型协议及系统选择器回调是明确替身，不能据此宣称完整模型质量或手工选择器认证。

开发0.5B模型仍是产品锁定配置。此前版本已验证其沙箱受管生命周期与read→search_text界面；新Runtime升级的模型组件、普通打包和实际模型回归以最新执行台账为准，不沿用旧二进制摘要。独立服务端7B候选已通过一个真实问答后批准读取及恢复不重放场景，但未进入默认桌面模型目录，不能用它替代默认0.5B验证。

普通macOS ARM64开发app与产物摘要由`scripts/check-flutter.py`写入`.local/build-evidence/flutter-macos.json`，并严格验证deep签名。开发签名不等于生产签名、公证、其他操作系统或低版本macOS认证；当前后端最低版本仍27.2。默认组件包不包含测试权重。完整测试权重夹具与恢复流程见[模型组件打包](model-service-packaging.md)。

此前通过计算机使用观察的系统选择器授权属于既有版本的独立历史证据。新的自动化用例均使用自己的临时目录；不读取、改写或撤销用户此前选定的真实目录。自动置前仍可能有系统警告，因此后台集成成功也不作为完整可访问性认证。

历史Runtime376f883及5847125的测试和制品摘要保留在Git历史和执行台账。它们是已验证的旧基线，不代表当前问答版本的发布资格。完整多轮交互、云身份、持久OS书签、孤儿恢复、Windows/Linux/GPU与全部G0—G6能力仍需继续实现和分别验证。

本次路径保护升级仅对保护名单计算Unicode兼容与展开大小写比较键，不更改实际路径、参数摘要或正常Unicode文件名。服务端先复现真实受保护夹具泄露，修复后59项Runtime及99项独立共享工作区测试通过。桌面新增Bridge与实际FRB/IPC回归，正式验收结果以当前执行台账为准。
