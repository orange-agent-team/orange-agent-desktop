import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var platformChannel: FlutterMethodChannel?
  private var selections: [String: (URL, Bool)] = [:]
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
      if call.method == "chooseWorkspace" {
        guard !self.pickerActive else { result(FlutterError(code: "PICKER_BUSY", message: nil, details: nil)); return }
        self.pickerActive = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "允许只读访问"
        panel.message = "请选择 Orange Agent 可读取的工作区。不会授予写入或执行程序的权限。"
        panel.beginSheetModal(for: self) { response in
          self.pickerActive = false
          guard response == .OK, let url = panel.url else { result(nil); return }
          let normalized = url.resolvingSymlinksInPath().standardizedFileURL
          let selection = UUID().uuidString
          let scoped = normalized.startAccessingSecurityScopedResource()
          self.selections[selection] = (normalized, scoped)
          result(["selectionId": selection, "path": normalized.path])
        }
        return
      }
      if call.method == "releaseWorkspaceSelection" {
        guard let arguments = call.arguments as? [String: Any], let id = arguments["selectionId"] as? String else {
          result(FlutterError(code: "INVALID_SELECTION", message: nil, details: nil)); return
        }
        if let (url, scoped) = self.selections.removeValue(forKey: id), scoped { url.stopAccessingSecurityScopedResource() }
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
    for (_, (url, scoped)) in selections where scoped { url.stopAccessingSecurityScopedResource() }
  }
}
