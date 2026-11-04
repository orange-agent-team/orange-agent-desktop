# 桌面仓库实施架构

2026-11-04；当前为E05/E06首个可实施切片，仍不是完整G3桌面端。

## 所有权与调用

`apps/desktop` 是Flutter应用E06；`crates/desktop-bridge` 是Rust桥接E05。Flutter通过FRB 2.13.0的配对生成物调用经过审阅的DTO和命令，Native Assets hook编译/打包Rust库。当前没有额外业务工程、Node BFF或Cargokit拷贝。

E01领域、E02协议、E03 Runtime、E04模型适配仍由服务端仓库维护。桌面消费固定提交`628cd5f3acb340c7349bfc8822f3f167e3020718`的源码发行包；`config/runtime.lock.json`绑定整个archive和release manifest摘要，`vendor/runtime-628cd5f`保存独立构建需要的源码。供应方只从Git commit导出，不从工作树复制未提交内容；接收方校验全部文件与来源清单。vendor中的副本不改变核心工程所有权，也不按新增项目统计。

桌面虚拟Cargo workspace只有E05，明确排除vendor中的共享workspace，防止其继承桌面错误的依赖定义。依赖锁从已验证Runtime锁出发，增加固定FRB依赖；真实客户端锁记录在桌面根Cargo.lock。E04源码随固定包提供，当前E05并未启动任何模型引擎。

## 当前真实接口

| 命令 | 行为 | 权限与副作用 |
|---|---|---|
| `initializeHost(applicationDataDirectory)` | 打开私有SQLite Journal并返回当前应用Host句柄；同上下文重复初始化返回同一句柄 | 目录来自可信UI的OS适配；必须绝对路径、符合私有目录要求。不授予工作区访问、不登录云端、不启动模型 |
| `inspectHost(handle)` | 返回本应用上下文的协议/Runtime版本和编译工具目录 | 只接受当前句柄；没有任意Rust对象或数据库连接暴露 |
| `validateAmount(handle,value)` | 用共享E01验证非负i64规范十进制字符串，原样无损返回 | 纯校验，不创建预算、不冻结余额、不收款 |
| `closeHost(handle)` | 关闭当前本地存储句柄；再次打开生成新句柄 | 不表示GPU已释放，也不表示任何未来Job已取消 |

可见DTO只有`HostView`和`BridgeError`。错误带稳定code和随机correlation ID，不透出底层路径或SQL错误。Host/HostRegistry及其Default实现移出FRB输入命名空间；生成脚本自动核对允许的类和函数集合，避免内部对象意外导出。

Rust持有Journal与独占锁。句柄不可猜测且绑定当前进程应用上下文，关闭后不能使用旧句柄操作新Host。FRB默认异步投递到Rust线程；不是通过Dart字段缓存来决定权限或金额有效性。

macOS通过一个受限Flutter MethodChannel调用Foundation获取Application Support目录，以遵循App Sandbox目录规则。该通道只返回OS应用目录，不暴露任意命令、文件读取或PID控制。Windows/Linux当前配置使用各自应用数据根约定，尚未进行真实目标平台认证。

## 生成代码与安全检查

FRB生成Rust/Dart配对内容摘要，构建前检查`config/generated-bridge.lock.json`；修改API、Host实现、依赖锁或生成物后必须重新生成和验证。生成脚本最后使用项目Rust edition对应的rustfmt格式化，不手工改生成代码业务逻辑。

第三方生成的FFI胶水需要unsafe，并包含SSE codec断言。只有`frb_generated`模块允许这些上游生成行为；手写Host仍禁止unsafe并执行Clippy unwrap检查。生成文件摘要、限定导出面和真实原生负例共同验证这个边界。此处不声称已完成任意恶意FFI字节的模糊测试，FRB也不是网络或OS权限隔离层。

## 后续接口演进

接续E05-W02～W04：工作区授权记录与撤销、Run启动/推进/批准/取消、持久事件游标、慢消费者背压、成果句柄和退出排空。不得在Dart里复制E03执行状态机，不得让模型批准工具。

模型与GPU引擎由独立受管进程执行；桌面UI进程不加载GPU模型。接E08 Broker时必须区分本地存储关闭、Run取消、引擎退出和设备清理证据。云账户将接单独的原生授权流程，不能复用Admin cookie或把Web开发token复制到桌面。

UI当前只展示真实本地记录状态和开发预览边界；没有假余额、假模型响应或假供给成功页面。其余既定页面和功能仍在总计划中待实现。
