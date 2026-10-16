import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentInteractionControllerDelegate {
  private var documentController: UIDocumentInteractionController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    UNUserNotificationCenter.current().delegate = self
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "lab_workspace/native_files",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self,
              let arguments = call.arguments as? [String: Any],
              let rawPath = arguments["path"] as? String,
              let fileURL = self.authorizedTemporaryFile(rawPath) else {
          result(FlutterError(code: "FILE_PATH_DENIED", message: "The selected path is outside app temporary storage.", details: nil))
          return
        }
        switch call.method {
        case "openFile": self.openFile(fileURL, result: result)
        case "shareFile": self.shareFile(fileURL, result: result)
        case "revealFile": result(false)
        default: result(FlutterMethodNotImplemented)
        }
      }
      let calculationChannel = FlutterMethodChannel(
        name: "lab_workspace/calculation_executor",
        binaryMessenger: controller.binaryMessenger
      )
      calculationChannel.setMethodCallHandler { call, result in
        guard ["probe", "execute", "requestCancel", "getLogs", "quantifyRoi"].contains(call.method) else {
          result(FlutterMethodNotImplemented)
          return
        }
        let arguments = call.arguments as? [String: Any]
        guard let requestJSON = arguments?["requestJson"] as? String,
              requestJSON.utf8.count <= 32 * 1024 * 1024 else {
          result(FlutterError(code: "INVALID_RPC_REQUEST", message: "A bounded JSON-RPC requestJson is required.", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let response: String
          if call.method == "probe" {
            response = LabCalculationPythonRunner.probeJSONRPC()
          } else {
            do {
              response = try LabCalculationPythonRunner.handleJSONRPC(requestJSON)
                ?? "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32010,\"message\":\"TRUSTED_PYTHON_RUNTIME_UNAVAILABLE\"}}"
            } catch {
              response = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32010,\"message\":\"TRUSTED_PYTHON_RUNTIME_UNAVAILABLE\"}}"
            }
          }
          DispatchQueue.main.async { result(response) }
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func authorizedTemporaryFile(_ path: String) -> URL? {
    let fileURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let cacheRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("lab_workspace_open", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard fileURL.path.hasPrefix(cacheRoot.path + "/"),
          FileManager.default.fileExists(atPath: fileURL.path),
          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return fileURL
  }

  private func openFile(_ url: URL, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            let controller = self.window?.rootViewController else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Could not open the file viewer.", details: nil))
        return
      }
      let interaction = UIDocumentInteractionController(url: url)
      interaction.delegate = self
      self.documentController = interaction
      if !interaction.presentPreview(animated: true) {
        if !interaction.presentOptionsMenu(from: controller.view.bounds, in: controller.view, animated: true) {
          result(FlutterError(code: "NO_FILE_VIEWER", message: "No system viewer is available for this file.", details: nil))
          return
        }
      }
      result(true)
    }
  }

  private func shareFile(_ url: URL, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            let controller = self.window?.rootViewController else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Could not open the share sheet.", details: nil))
        return
      }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = controller.view
        popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
      }
      controller.present(activity, animated: true)
      result(true)
    }
  }

  func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    window?.rootViewController ?? UIViewController()
  }
}
