# 本地模型安装与受管生命周期

2026-11-05。当前实现面向固定Qwen GGUF与macOS ARM64 CPU后端，是可验证的开发功能切片。真实沙箱应用已完成安装、启动、空闲心跳、Agent工具批准与停止；下载/卸载、孤儿进程核对、其他后端/OS/GPU和生产签名仍未完成。

## 构建与信任边界

Native Assets先校验Runtime源码与暂存模型组件，再将整个组件manifest的SHA-256通过`ORANGE_MODEL_BUNDLE_SHA256`绑定进Rust库。运行时配置必须同时匹配该摘要、固定Runtime提交、后端提交、模型清单、实际程序字节与本机OS约束。仅把可执行文件改掉再重算旁边manifest，不能通过已构建应用的检查。没有组件的构建明确返回`MODEL_SERVICE_NOT_PACKAGED`。

`Bundle`只使用固定的Helpers/Resources路径，不接受模型生成的命令或URL。数据、profile、控制nonce、管理记录和模型缓存位于Host私有目录，短IPC目录在系统私有临时空间中预留保护。文件打开检查普通文件、权限、链接数与打开前后身份；读入与摘要计算有大小上限。配置写入采用私有临时文件、同步和原子改名。

## 执行所有权

SQLite命令执行器与模型服务所有者是两个独立线程。模型线程持续驱动自己的Tokio runtime，即使界面和Journal都没有命令，也会每5秒向实际模型宿主发送心跳。控制写入有2秒上限，启动等待和15秒退出确认也有界。模型宿主继续使用私有父认证、控制EOF、实际子进程及继承执行租约。

启动请求编号由可信UI在调用前生成，模型实例编号由Rust另外生成。`manager.json`保存请求、实例、结果和提前取消的请求编号，拒绝重复编号、未知格式与未知状态；当前分别限制256条启动/取消记录。旧启动请求在重开后返回原结果，不启动另一个模型；旧实例停止请求不能停止新实例。

停止信号位于Journal队列之外，先禁止新的模型调用并打断关联Run，再提交Run停止状态及等待实际模型退出。只有已拥有的宿主退出，且核心进程记录中的实例、模型/程序摘要、别名、CPU标记和stopped状态匹配，才返回stopped。关闭Host立即使句柄失效并请求清理，不把句柄关闭当作资源释放证明。

启动时发现不属于当前控制器的ready/unknown记录，进入`recovery_required`。记录中的PID只是被解析的数据，不是终止权限。控制器不会凭旧PID发送信号，也不会把不确定清理改写成空闲。已有停止收据与控制租约的确认用于正常重开；完整OS作业级孤儿恢复仍待实现。

## FRB管理接口

| 接口 | 输入/结果 | 约束 |
| --- | --- | --- |
| `configureModelService` | handle、原生Contents/IPC路径、OS版本 → ModelServiceView | 校验编译绑定、模型目录与已有状态，不自动启动模型 |
| `inspectModelService` | handle → ModelServiceView | 队列外读取，可在启动或Journal等待时查询 |
| `importModel` | handle、operationId、系统所选文件 → ModelServiceView | 固定模型大小/magic/SHA，真实私有复制与配额，不改源文件 |
| `closeModelImport` | handle、operationId → 空 | 按预先已知编号停止/排空导入，阻止关闭后的延迟请求，再释放系统文件scope |
| `startModelService` | handle、requestId → ModelServiceView | 持久幂等；实例实际ready并健康检查通过后才发布Agent连接 |
| `cancelModelStart` | handle、requestId → ModelServiceView | 未收到实例编号也能取消；提前关闭记录持久保存 |
| `stopModelService` | handle、instanceId → ModelServiceView | 只停止当前已拥有的实例，不能重用旧目标 |
| `currentModelConnection` | handle → ModelConnectionView | 只为就绪的受管服务取得/恢复经过健康校验的连接，不启动模型 |

ModelServiceView包含phase、模型名称、规范十进制文件字节数、最近校验的installed、instanceId和安全错误码。phase为idle、starting、ready、stopping、stopped或recovery_required；installed不代替启动前的重新校验。坏模型已知失败会清除installed状态。错误不泄露控制nonce、模型API key或底层SQL。

## 界面与权限

默认应用提供“导入模型文件”“启动本地模型”“停止本地模型”和状态核对。导入使用真实NSOpenPanel只读文件选择；Rust确认导入结束/停止后才释放对应系统访问。取消不会承诺删除已经原子发布的有效缓存。

会话连接只有在受管服务实际ready后才可用；缺失组件、权重错误、系统不兼容或不确定进程均明确拒绝。停止模型会打断当前相关会话。客户端操作世代和状态查询序号抑制晚到响应，失败时核对实际状态，不能把旧stopped/ready画面当作新操作成功。

## 验证与未完成范围

`scripts/check-managed-model.py --model PATH`要求明确提供固定权重。脚本在构建锁下临时添加验证载荷，运行两个真实原生测试，再恢复原组件包并清理生成的hook缓存；普通开发包不因此附带测试权重。

实际验证包括完整GGUF导入、无Journal命令35秒心跳、真实模型读取批准后的独有文件内容、错误实例停止拒绝、关闭活动Host后实际清理、跨重启启动去重/取消保留，以及拒绝接管伪造的未归属ready记录。第二个测试实际点击产品导入/启动/会话批准/停止按钮；模型与Rust执行均真实，系统文件/目录选择回调是明确测试fixture。恢复被测试主动改写的进程记录仅用于fixture清理，不是产品恢复实现。

另有编译摘要绑定负例，证明重新计算可变manifest不能绕过构建时的摘要，模型清单也独立核对。完整应用仍不等于G0—G6交付：多轮会话、后台作业恢复、模型目录管理/卸载/下载、其他模型协议、云Host、真实GPU和长期稳定性等按原计划继续。

独立QA副本`dev.orangeagent.qa.fa686dbe`另经真实NSOpenPanel选择公开权重和自建目录，观察到校验导入、服务就绪及只读工具批准请求。界面工具随后无法建立native pipe，手工批准未记为完成；只读运行元数据显示仍为tools_pending、一个intended操作。按实时核对的独立launchd作业身份结束QA应用后，模型停止收据与执行租约均确认，未按状态文件PID操作进程。观察元数据保存在`.local/ui-model-qa/fa686dbe/qa-observation.json`；不保存系统文件列表或任何密钥。此手工观察补充真实选择器，完整结果/批准/停止链路仍以原生自动化测试为依据。
