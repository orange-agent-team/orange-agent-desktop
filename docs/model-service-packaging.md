# 模型组件打包与本地导入

2026-11-05。当前交付可校验的开发组件包、实际沙箱子程序启动探测和Rust缓存导入接口。固定CPU模型的安装与应用拥有的启动/停止控制器已继续实现，实际验证见[受管模型服务](managed-model-service.md)。单独的打包检查仍不能代替运行验证。

## 固定输入与产物

`python3 scripts/prepare-model-bundle.py --backend PATH --build-manifest PATH --backend-checkout PATH`。

三个输入都必须明确提供；普通构建不查找相邻服务端源码。宿主从本仓库固定Runtime发行物独立离线编译，使用桌面锁定的Rust工具链；CPU后端必须匹配明确提供的构建记录、固定llama.cpp提交和二进制摘要。后端构建记录中的源码树摘要保留为生产方证据，打包器没有重新构建该后端或证明编译器可信。

准备器只针对当前可用的macOS ARM64目标，检查两个Mach-O的架构、最低系统版本与动态依赖；目前只接受系统库。复制后再次核对摘要，再以ad-hoc方式签名。两个子程序均只有`app-sandbox`与`inherit`两项沙箱权限，继承父应用的静态权限。没有使用生产签名身份或关闭沙箱。

`.local/model-bundle/manifest.json`记录schema、Runtime/后端提交、模型描述符、逐文件字节数与SHA、签名前摘要、系统依赖、最低macOS版本及`development_only=true`。当前最低版本由实际后端决定，为27.2；不能按Flutter壳的12.0宣称整个模型组件支持macOS12。

同一暂存区的准备过程使用文件锁。仅替换已验证的旧组件，保留一个回退副本；链接、未知文件、错误摘要、版本不一致或缺少继承签名均拒绝。后端许可证从明确指定checkout的固定提交读取，随包保留原文；完整Rust依赖许可/SBOM审核仍待完成。

可选`--test-model PATH`只接受目录中固定摘要/大小的完整GGUF，将其标记为测试载荷。默认不打包权重，原生启动探测也不需要权重。不能把测试载荷误称为用户已安装或已批准的生产模型。

## 应用包布局

### 嵌入依赖与增量签名

Flutter嵌入步骤输出DerivedSources中的完成标记，模型嵌入步骤显式依赖该标记，并输出`Contents/Resources/orange-model-embed.json`。后者记录当前Runtime、模型清单及已嵌入框架的二进制/资源封装摘要，让测试权重、Dart目标或Native Assets变化进入构建依赖分析。无模型组件时也生成明确的空组件标记。

这是构建依赖记录，不是执行授权或签名替代品。仍由Xcode完成外层签名，`check-flutter.py`保留`codesign --verify --deep --strict`，不对失配资源临时重新签名来制造通过。测试包恢复为普通包的切换须单独验收。依据：[Apple构建脚本的输入输出声明](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build)、[构建阶段的依赖顺序](https://developer.apple.com/documentation/xcode/customizing-the-build-phases-of-a-target)。

2026-11-08：上述完整切换已实际通过，默认组件清单摘要为020bdf69cd802ade78c557fbb464db130f338ec9a738cce9157d9978907e1dc4；无测试权重，资源标记与当前框架/组件一致，严格签名和原沙箱只读权限检查通过。这仍是开发制品，不是生产签名或公证。

| 路径 | 内容 |
| --- | --- |
| `Contents/Helpers/orange-model-host` | Rust模型宿主，父控制认证、心跳、退出与监督 |
| `Contents/Helpers/llama-server` | 固定CPU后端 |
| `Contents/Resources/OrangeModelService/manifest.json` | 组件清单 |
| `Contents/Resources/OrangeModelService/licenses/` | 固定后端许可证清单 |
| `Contents/Resources/OrangeModelService/test-model.gguf` | 仅显式准备测试载荷时存在 |

Xcode在外层应用签名前调用`embed-model-service.py`。程序与数据分开放置：实际实验中把manifest放在Helpers会被codesign拒绝，未绕过该检查。脚本限制写入本工作区生成的macOS `.app/Contents`，拒绝Helpers/Resources链接，复制后验证清单与签名。没有组件包时明确构建为“未打包模型组件”，不隐式下载或调用其他工作区。

Debug、Profile或Release优化方式不改变`development_only`标记；Release构建本身不等于生产发布资格。`check-flutter.py`验证应用深层签名一致性和嵌入组件摘要，仍只形成开发构建证据。

Native Assets hook在调用Cargo前运行共享Runtime源码校验，避免直接执行Flutter构建时略过导入完整性检查。macOS平台通道`modelServiceEnvironment`只返回当前应用Contents目录、系统私有IPC目录和实际OS版本；不接受任意命令、PID或模型给出的路径，不授予文件权限。

## 私有模型导入

共享E04提供`ModelCache::import_file`和可取消版本。描述符来自固定配置，用户选择只提供源文件；输出为真正校验过的VerifiedArtifact。复制、配额、锁、摘要、magic及原子发布规则见服务端缓存文档。源位于自身缓存命名空间时拒绝，防止暂存源被截断；不会链接源文件或修改用户原文件。

`check-real-run.py`现先通过桌面Rust验收程序导入完整491400032字节Qwen权重到隔离Host私有缓存，验证第二次命中、源/目标inode独立和目标摘要，再用导入副本完成实际CPU Agent批准/读取/恢复流程。它证明内核导入及模型可用性；安装按钮、进程所有权和打包服务实际推理由独立的check-managed-model.py原生测试验证。

## 检查命令与边界

- `python3 scripts/check-model-bundle.py`：实际组件清单、架构、系统库、签名、篡改/错误最低版本/资源链接拒绝。
- `python3 scripts/check-model-bundle.py --native`：再运行真实沙箱应用，执行打包后端的`--version`，运行打包宿主并验证错误父认证在创建密钥、租约或进程记录前拒绝。明确`modelStarted=false`。
- `python3 scripts/check-bridge.py --native`：既有会话UI、FRB、SQLite和文件工具流程；模型协议及系统选择回调仍是明确替身。
- `python3 scripts/check-real-run.py`加明确artifact参数：完整权重导入、缓存复用及真实CPU模型API闭环。

后续服务控制器必须持有实际子进程和私有控制通道，保持心跳，在启动/停止/取消/关闭竞态中按实例确认结果；不得用状态文件PID恢复终止权限。模型子进程不能依赖用户NSOpenPanel动态授予的工作区权限，文件工具继续由能力目录Host执行。需要继续实现安装/卸载、故障恢复、应用级生命周期及目标平台验证。
