# 独立导出位置检查

固定Runtime 84d797ca3f2eefdfd675e5d905664add292b713a/schema18提供目的目录独立读取能力。254共享测试含201Runtime通过；本功能保持已有导出记录不变，不涉及删除、回收额度或补造成功回执。

## 使用和数据边界

导出记录列表的“检查位置”独立选择本次导出目标目录，无需恢复源目录授权。页面分别显示已存记录状态、当前目标和暂存文件的存在性、大小、SHA、是否匹配批准包以及是否为有效数据包。目标与暂存均缺失也不推断从未发生效果；存在且匹配也不将unknown改成成功。历史成功回执不会因文件后来被外部修改而消失。

只有用户选择的目标目录与记录保存的物理目录一致才授权。错owner/Run/operation/export ID、错误目录、私有根、旧Host epoch和已关闭token被拒绝。符号链接、硬链接、非普通文件和超过3MiB的数据拒绝读取；读取前后复核名称、文件描述符、内容长度、权限和对象身份。

## Host / FRB

- authorize_export_inspection：独立native用途，返回会话、Run/operation/export ID和显示目录。不能复用源保留、导出写入、恢复或普通workspace token。
- inspect_export_files：只投影当前metadata，并在返回前复查撤权。没有原源路径、原件内容、内部暂存名、WorkspaceGrant或写入能力。
- suspend_export_inspection：先即时信号撤权，再由Actor等待实际读取租约排空，最后Dart才释放native目录权限。

检查会话不依赖源读取会话，不会打开源目录或恢复普通Agent能力。Host关闭撤销全部检查；父页面停止、导航和销毁关闭独立检查，迟到选择/响应不能重新显示数据。关闭失败保留native拥有关系并允许重试。

## 界面行为

记录ID与不可变review摘要必须与返回检查一致。unknown/succeeded终态不能被返回快照改写。页面明确将匹配标记表述为当前文件事实，unknown仍显示“记录仍待核对”。本入口只读，没有确认原操作成功、重新发布或删除按钮。

## 验证

- Rust Host：关闭源和目的写scope后实际读取导出文件；错Run/目录和迟到选择拒绝；检查token不能用作导出源或写入scope；持有真实receipt时关闭等待排空，撤权后view不可读。原有12项Rust/Clippy及其他流程保留。
- 新增7项UI/控制器用例：matching未知状态不提升、错摘要/终态拒绝、迟到选择/快照隐藏、释放失败重试、父关闭释放独立检查且不打开源权限。
- scripts/check-export-inspection.py实际签名macOS/FRB通过93837（export-inspection-native-acceptance.log）：真实导出与回执故障unknown→重开→将自有源目录移走使原路径不可用→从记录列表独立选择目的目录→观察真实匹配文件但保留unknown→关闭检查后API拒绝读取。源2份、导出2份文件不变。
- 模型和系统选择器回调为明确替身；文件、SQLite、FRB、签名应用和撤权/排空真实执行。人工选择器、其他OS及文件系统和清理安全不由此认证。

## 后续明确处置

清理/删除另需独立写授权、精确批准、持久派发与回执，以及旧export worker是否停止、目标对象和命名空间并发变化的证据。静态检查快照不是writer停止证明，更不是删除授权。当前不自动清理未知文件，不释放归档额度，也不代表完整数据退出或G0—G6验收。
