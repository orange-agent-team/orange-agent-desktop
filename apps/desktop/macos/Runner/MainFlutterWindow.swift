import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var platformChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    platformChannel = FlutterMethodChannel(
      name: "orange_agent/platform",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    platformChannel?.setMethodCallHandler { call, result in
      guard call.method == "applicationSupportDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first else {
        result(FlutterError(code: "DATA_DIRECTORY_UNAVAILABLE", message: nil, details: nil))
        return
      }
      result(directory.appendingPathComponent("OrangeAgent", isDirectory: true).path)
    }

    super.awakeFromNib()
  }
}
