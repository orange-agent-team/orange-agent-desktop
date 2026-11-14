# 保留原件管理

本候选固定消费 Runtime `a2cdafb95fab90bc1ded82d4a4c061be40463d35`（schema17）。归档和来源摘要见 `config/runtime.lock.json`；普通构建不读取相邻仓库。共享包248项测试、195项Runtime测试及严格Clippy通过。新增接口只用于可信宿主，不增加模型工具。

## 用户流程

保留原件管理页按Run和操作分页列出成功发布、已独立解决的unknown及已归档编辑。未解决的unknown仍从恢复检查入口处理。列表只返回操作ID；用户另外选择原目录后才显示当前原件、暂存文件状态及预留额度。

“生成归档预览”不改变归档记账。页面显示文件状态、预留字节及精确摘要，只有“确认本次原地归档”才提交。归档将活动预留转入拥有者归档预留，文件留在原目录、原inode上，不释放物理磁盘空间，也不是不可变备份。现有上限256MiB/1000条用于准入预留；不能把它显示为真实磁盘使用量。归档原件仍可能被其他程序的旧描述符修改，后续观察会标记与登记时不同。

原操作若为unknown，归档后仍为unknown；它不会重新运行Agent或把原任务改为成功。导出和删除未实现，本页面没有这两项入口，也不会自动删除原件腾容量。

## API与权限边界

| 接口 | 契约 |
|---|---|
| list_retained_edits | 当前本地拥有者、Run内的操作ID，1—100条，严格倒序游标，无文件能力 |
| inspect_retention_outcome | 已提交归档review ID或None；关闭文件授权后仍可核对，不重发批准 |
| authorize_retention_access | 独立native选择token、当前workspace版本、owner/Run/operation/物理目录/Host epoch绑定 |
| inspect_retention | 当前受限文件状态和预留额度，保留读租约到投影完成；变化标记与同一快照比较 |
| prepare_retention_archive | 限时精确预览；不改变归档记账，新预览替代旧预览 |
| approve_retention_archive | 消耗当前预览，精确摘要确认；同一桥接批准不可重放，文件变化拒绝 |
| suspend_retention_access | 即时撤权信号→Actor排空→移除会话；Dart确认完成后才释放native目录权限 |

FRB公开接口经清单审核和成对生成。保留管理token不能作为恢复写入、普通Run或其他目录授权；Swift选择器也按retention用途检查释放。工作区撤权与Host关闭同步关闭这些会话；失效工作区版本不得撤销新的选择。无编辑能力的目标明确返回EDITING_UNAVAILABLE_ON_TARGET。

选择迟到、导航或工作区撤权会使原请求失效；迟到结果不恢复展示。清理失败保留native拥有关系并显示错误，不能假称已释放。批准回复丢失时仅查询一次review ID，必须与当前确认ID一致才显示登记完成；None/其他ID/查询错误均显示结果未确认，不自动重发。

## 验证范围

- 9项Rust Host测试及Clippy：真实临时文件/SQLite的归档、当前版本选择、跨用途拒绝、晚到选择、旧预览及重复批准拒绝、实际读取租约排空；模型协议替身明确标注。
- 42项Flutter组件测试，包括新增8项归档UI/控制器测试：明确点击确认才产生批准、丢失回复只查询、错误review不显示成功、停止期间迟到成功隐藏、迟到选择释放、清理失败可重试及跨Run快照拒绝。
- `python3 scripts/check-retention.py` 实际macOS/Flutter/FRB集成：真实编辑→Host重开→独立选择→真实观察和预览→实际归档后丢弃回复→仅查询一次→仍保留两份文件→关闭选择后核对→Host重开确认归档记录。90182通过，日志retention-native-acceptance-2.log。
- 新测试的模型与系统选择器回调是明确替身；文件效果、SQLite、FRB、原生应用与撤权/排空真实执行。没有认证人工系统选择器、实际外部模型质量、其他OS或生产签名。

共用恢复会话生命周期回归和默认包恢复结果记录在统一执行台账。此功能完成证据不能替代完整G0—G6或数据退出能力的验收。
