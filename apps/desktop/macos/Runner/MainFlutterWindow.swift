import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private var platformChannel: FlutterMethodChannel?
  private var selections: [String: (URL, Bool, String)] = [:]
  private var pickerActive = false
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    platformChannel = FlutterMethodChannel(
      name: "orange_agent/platform",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    platformChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "WINDOW_CLOSED", message: nil, details: nil)); return }
      if call.method == "modelServiceEnvironment" {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        result([
          "contentsDirectory": Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true).path,
          "ipcDirectory": FileManager.default.temporaryDirectory.appendingPathComponent("om", isDirectory: true).path,
          "osVersion": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        ])
        return
      }
      if call.method == "chooseWorkspace" || call.method == "chooseModelFile" || call.method == "chooseCreationWorkspace" || call.method == "chooseEditingWorkspace" || call.method == "chooseRecoveryInspectionWorkspace" || call.method == "chooseRecoveryWriteWorkspace" || call.method == "chooseRetentionWorkspace" || call.method == "chooseExportDestination" || call.method == "chooseExportInspectionDirectory" || call.method == "chooseExportRetirementDirectory" {
        guard !self.pickerActive else { result(FlutterError(code: "PICKER_BUSY", message: nil, details: nil)); return }
        self.pickerActive = true
        let panel = NSOpenPanel()
        let modelSelection = call.method == "chooseModelFile"
        let createSelection = call.method == "chooseCreationWorkspace"
        let editSelection = call.method == "chooseEditingWorkspace"
        let inspectionSelection = call.method == "chooseRecoveryInspectionWorkspace"
        let recoveryWriteSelection = call.method == "chooseRecoveryWriteWorkspace"
        let retentionSelection = call.method == "chooseRetentionWorkspace"
        let exportSelection = call.method == "chooseExportDestination"
        let exportRetirement = call.method == "chooseExportRetirementDirectory"
        let exportInspection = call.method == "chooseExportInspectionDirectory"
        panel.canChooseDirectories = !modelSelection
        panel.canChooseFiles = modelSelection
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = modelSelection ? "导入模型" : (createSelection ? "允许提出新建请求" : "允许 Agent 读取")
        panel.message = modelSelection ? "请选择清单对应的 GGUF 文件。仅在大小与摘要校验通过后复制到应用缓存，不修改原文件。" : (createSelection ? "请选择与工作区相同的文件夹。Agent 只能在单独批准后创建新文件，不会覆盖现有文件。" : "请选择 Agent 可读取的工作区。本次仅开启 Agent 只读工具；文件创建和编辑需要另行授权，执行程序不在此权限内。")
        if editSelection {
          panel.prompt = "允许提出编辑请求"
          panel.message = "请选择与工作区相同的文件夹。每次修改现有文件都必须核对实际差异后单独批准；此授权不包含删除文件或执行程序。"
        }
        if inspectionSelection {
          panel.prompt = "允许恢复检查"
          panel.message = "请选择待核对运行的工作区。本次只读取文件状态；恢复写入需要另行授权并批准具体决定。"
        }
        if recoveryWriteSelection {
          panel.prompt = "允许处理待核对改动"
          panel.message = "请选择与检查目录相同的工作区。此权限仅用于已选改动的恢复处理；每个具体决定仍需核对实际状态后单独批准。"
        }
        if retentionSelection {
          panel.prompt = "管理保留原件"
          panel.message = "请选择对应运行的原工作区。查看保留版本后可单独确认原地归档；不会移动、删除文件或继续原任务。"
        }
        if exportSelection {
          panel.prompt = "选择导出目录"
          panel.message = "数据包将包含所选保留版本的实际内容。预览文件名、大小和摘要后仍需单独确认；不会覆盖已有文件或删除原件。"
        }
        if exportInspection {
          panel.prompt = "只读检查导出位置"
          panel.message = "请选择这条导出记录对应的目标目录。查看当前目标与暂存文件状态；不会恢复原目录权限。"
        }
        if exportRetirement {
          panel.prompt = "允许移入保留区"
          panel.message = "请选择当前检查的导出目录。核对具体文件后还需单独批准移出；文件保留在该目录的保留区，不会永久删除或释放空间。"
        }
        if modelSelection { panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data] }
        panel.beginSheetModal(for: self) { response in
          self.pickerActive = false
          guard response == .OK, let url = panel.url else { result(nil); return }
          let normalized = url.resolvingSymlinksInPath().standardizedFileURL
          let selection = UUID().uuidString
          let scoped = normalized.startAccessingSecurityScopedResource()
          let purpose = exportRetirement ? "export_retirement" : exportInspection ? "export_inspection" : exportSelection ? "export" : retentionSelection ? "retention" : modelSelection ? "model" : (createSelection ? "creation" : (editSelection ? "editing" : (inspectionSelection ? "recovery_inspection" : (recoveryWriteSelection ? "recovery_write" : "workspace"))))
          self.selections[selection] = (normalized, scoped, purpose)
          result(["selectionId": selection, "path": normalized.path])
        }
        return
      }
      if call.method == "releaseWorkspaceSelection" || call.method == "releaseModelSelection" || call.method == "releaseCreationSelection" || call.method == "releaseEditingSelection" || call.method == "releaseRecoveryInspectionSelection" || call.method == "releaseRecoveryWriteSelection" || call.method == "releaseRetentionSelection" || call.method == "releaseExportDestinationSelection" || call.method == "releaseExportInspectionSelection" || call.method == "releaseExportRetirementSelection" {
        guard let arguments = call.arguments as? [String: Any], let id = arguments["selectionId"] as? String else {
          result(FlutterError(code: "INVALID_SELECTION", message: nil, details: nil)); return
        }
        let purpose = call.method == "releaseExportRetirementSelection" ? "export_retirement" : call.method == "releaseExportInspectionSelection" ? "export_inspection" : call.method == "releaseExportDestinationSelection" ? "export" : call.method == "releaseRetentionSelection" ? "retention" : call.method == "releaseModelSelection" ? "model" : (call.method == "releaseCreationSelection" ? "creation" : (call.method == "releaseEditingSelection" ? "editing" : (call.method == "releaseRecoveryInspectionSelection" ? "recovery_inspection" : (call.method == "releaseRecoveryWriteSelection" ? "recovery_write" : "workspace"))))
        if let (_, _, actual) = self.selections[id], actual != purpose {
          result(FlutterError(code: "SELECTION_PURPOSE_MISMATCH", message: nil, details: nil)); return
        }
        if let (url, scoped, _) = self.selections.removeValue(forKey: id), scoped { url.stopAccessingSecurityScopedResource() }
        result(nil)
        return
      }
      guard call.method == "applicationSupportDirectory" else { result(FlutterMethodNotImplemented); return }
      guard let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first else {
        result(FlutterError(code: "DATA_DIRECTORY_UNAVAILABLE", message: nil, details: nil))
        return
      }
      result(directory.appendingPathComponent("OrangeAgent", isDirectory: true).path)
    }

    super.awakeFromNib()
  }

  deinit {
    for (_, (url, scoped, _)) in selections where scoped { url.stopAccessingSecurityScopedResource() }
  }
}
