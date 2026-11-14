# 本地模型异常退出证据

原失败的真实UI用例已批准read_file，但模型服务在执行前退出；原程序将helper stderr丢弃，并在确认清理后保存stopped/无失败原因。旧日志无法确定退出根因，不能宣称是App Nap、资源压力、签名或模型质量导致，也不能把一次重跑通过当成根因修复。

本变更补齐状态与证据：

- 持续排空helper stderr，只在最多128字节尾部窗口内识别固定分类。原始stderr、路径、控制nonce、模型内容和密钥都不保存；其他文本不会被当成正常退出的失败原因。
- 确认helper已退出且已有有效backend停止记录后，将意外退出分类保存在manager记录；私有failure.json只保存实例、固定原因、helper退出码/信号及心跳间隔。诊断文件只代表其注明的实例，不能视为当前实例的证明。
- 诊断写入失败仍保持已确认停止，并明确报告诊断不可用；backend停止记录无法读取/验证则进入recovery_required，不留在ready，也不宣称清理成功。
- Agent advance返回MODEL_SERVICE_UNAVAILABLE时只刷新模型状态，保留并重新抛出原错误。不重启模型、不重发批准/工具/模型请求。界面显示当前停止状态与固定错误说明。

4项owner专项测试覆盖分块stderr分类、不保存原始文本、正常停止、意外退出、诊断写入失败与无效停止记录。自有控制helper/receipt替身只验证状态处理，不冒充真实模型清理；真实模型/租约另由native验收验证。

隔离的真实UI用例及完整生命周期+UI顺序曾通过（model-exit-instrumented-reproduction.log / model-exit-instrumented-full.log），包括原35秒心跳、明确批准、真实读取/搜索与来源删除清理。最终代码的完整验证和默认App恢复记录在统一执行台账。原退出原因仍未证实，长期稳定性未认证；心跳期限与批准门槛没有放宽。
