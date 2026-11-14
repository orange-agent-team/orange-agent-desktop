# 保留版本导出

桌面固定消费 Runtime 84d797ca3f2eefdfd675e5d905664add292b713a/schema18；归档和来源摘要见config/runtime.lock.json。254项共享测试（含201Runtime）通过，不隐式读取相邻仓库源码，也不新增模型工具。

## 用户操作

在保留原件管理中选择运行和操作，单独授权查看原目录，再单独选择导出目标。页面显示目标目录、文件名、选择的版本、实际大小及SHA-256；生成预览不会写文件。只有确认这个具体预览后才创建数据包，已有目标（包括晚到目标）不覆盖。文件名必须是单个名称并以.orange-retained.json结尾。

数据包包含实际文件内容（base64），不是加密备份。原件位置或暂存位置被外部修改时导出当前观察到的内容，并标注是否匹配原审阅版本；不伪装成不可变原件。导出不删除原件、不释放归档额度，也不继续原Run。导出记录是已存状态，不表示目标文件此后未被外部修改。

## 授权与生命周期

目的目录具有独立native用途、Host会话和信号，绑定源保留读取token、Run/operation、workspace和当前Host epoch；不能复用普通、保留读取、恢复写入或其他选择token。选择迟到会被关闭；源关闭、工作区撤权和Host关闭会撤销其目的子会话。

Host只缓存不可序列化PreparedRetentionExport。它持有源与目标租约；替换预览、导航或关闭时先丢弃未派发缓存，再等待排空，最后释放native目录权限。派发中的准备结果归worker拥有，撤权信号不等待Actor。Dart按目的→源的顺序关闭，释放失败保留拥有关系并显示可重试错误。

## 接口

| API | 行为 |
|---|---|
| authorize_export_destination | 独立native目的目录选择，绑定已有保留读取会话 |
| prepare_export | 返回元数据预览：两个token、Run/operation/export ID、目标名、版本摘要、包大小/摘要和有效期；不返回原件内容或内部暂存名 |
| approve_export | 消耗当前缓存的export ID/digest，先持久派发再排他发布；旧/错误/过期/跨scope/重复批准拒绝 |
| inspect_export_outcome | 按拥有者绑定核对已知ID，不恢复文件权限；回复丢失仅查询一次 |
| list_export_outcomes | owner/Run/operation内有界元数据分页，重开无文件scope也能发现prepared/succeeded/unknown；游标为ID倒序，不是时间排序 |
| suspend_export_destination | 先信号撤权，清除缓存并等待租约结束，之后才释放native目录权限 |

只有ID和确认摘要都匹配的succeeded回执才能显示已确认。None、其他ID/digest、unknown或查询错误不会当作成功，不能自动重发或清理。列表刷新失败不推翻已经验证的成功回执。Runtime按同目录0600新建、同步、内容/inode核对、NOREPLACE发布及目录同步工作；不能承诺全局原子内容CAS或防止外部后续修改。

## 实际验证与边界

- Runtime6个保留/导出测试含多个实际文件故障场景、schema17真实CLI升级与旧版非修改式拒绝；独立入口为server scripts/check-retention-export.py --legacy-runtime <固定a2cdafb源码>。
- 9项Rust Host测试/Clippy：实际文件导出、源/目的独立性、精确确认、重复拒绝、目的关闭不撤销源、源关闭清除子目的、缓存租约丢弃后排空与记录查询。
- 52项Flutter组件测试，包括新增10项导出流程：选择/预览无效果、明确点击后批准、丢失回复一次查询、错误回执拒绝、unknown可见、迟到选择/成功隐藏、改名失效旧预览、清理失败重试及历史刷新错误不伪造未确认。
- `python3 scripts/check-export.py`实际签名macOS/Flutter/FRB验收通过11947（export-native-acceptance-2.log）：真实编辑→重开→单独源/目的选择→精确确认→实际包内容/SHA-256/0600核对→已有目标拒绝→真实写入后SQLite回执故障保持unknown→未批准预览不发布→目的排空后源释放→重开发现三种记录。两次批准、两次查询，无重发；原目录两份文件保持、导出两份文件存在。
- 模型与系统选择器回调是明确替身；文件、SQLite、FRB、签名应用及撤权/排空真实执行。人工选择器、真实模型质量、其他OS和生产签名不由此认证。

原有保留/恢复流程回归和默认App恢复见统一执行台账。unknown导出的位置核对已支持独立只读检查，见export-inspection-preparation.md；明确清理、原件删除与额度释放仍是后续独立授权功能；成功导出不等于删除授权。本功能不代替完整数据退出或G0—G6验收。
