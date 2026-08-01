import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LoliSnatcherServices") {
      ServiceHandler.register(with: registrar)
    }
  }
}

/// iOS counterpart to MainActivity.kt's `com.noaisu.loliSnatcher/services` channel.
///
/// The Android side implements 40 methods, most of which are Storage Access
/// Framework calls with no iOS equivalent. This shim implements only the portable
/// subset; everything else falls through to `FlutterMethodNotImplemented`. That is
/// safe because every method in `lib/src/handlers/service_handler.dart` wraps
/// `invokeMethod` in a try/catch, so an unhandled method surfaces as a logged
/// `MissingPluginException` and a null/empty return rather than a crash.
enum ServiceHandler {
  private static let channelName = "com.noaisu.loliSnatcher/services"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
  }

  private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "getExtPath", "getDocumentsPath":
      result(directory(.documentDirectory))

    case "getCachePath":
      result(directory(.cachesDirectory))

    case "emptyCache":
      emptyCache()
      result(nil)

    case "disableSleep":
      UIApplication.shared.isIdleTimerDisabled = true
      result(nil)

    case "enableSleep":
      UIApplication.shared.isIdleTimerDisabled = false
      result(nil)

    case "shareText":
      guard let text = args["text"] as? String else {
        result(argumentError("text"))
        return
      }
      share(items: [text], result: result)

    case "shareFile":
      guard let path = args["path"] as? String else {
        result(argumentError("path"))
        return
      }
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else {
        result(
          FlutterError(
            code: "file_not_found",
            message: "No file at \(path)",
            details: nil
          )
        )
        return
      }
      var items: [Any] = [url]
      if let text = args["text"] as? String, !text.isEmpty {
        items.append(text)
      }
      share(items: items, result: result)

    // Android's MediaScanner has no iOS analogue. Files land in the app's
    // Documents directory and are surfaced through the Files app instead
    // (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace in Info.plist).
    case "scanMedia":
      result(nil)

    // Deliberately 0. Callers gate Android-version-specific behaviour on this,
    // and 0 keeps every SDK-gated branch (notably the SAF paths, which require
    // >= 31) switched off.
    case "getSdkVersion":
      result(0)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Helpers

  private static func directory(_ target: FileManager.SearchPathDirectory) -> String {
    return NSSearchPathForDirectoriesInDomains(target, .userDomainMask, true).first ?? ""
  }

  private static func emptyCache() {
    let fm = FileManager.default
    let caches = directory(.cachesDirectory)
    guard !caches.isEmpty,
      let entries = try? fm.contentsOfDirectory(atPath: caches)
    else { return }

    for entry in entries {
      try? fm.removeItem(atPath: (caches as NSString).appendingPathComponent(entry))
    }
  }

  private static func argumentError(_ name: String) -> FlutterError {
    return FlutterError(
      code: "bad_arguments",
      message: "Missing required argument: \(name)",
      details: nil
    )
  }

  /// The scene-based template means there is no `window` on the app delegate,
  /// so the presenting controller has to come from the active window scene.
  private static var topViewController: UIViewController? {
    let window =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }?
      .windows.first { $0.isKeyWindow }

    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private static func share(items: [Any], result: @escaping FlutterResult) {
    guard let controller = topViewController else {
      result(
        FlutterError(
          code: "no_view_controller",
          message: "No active view controller to present the share sheet from",
          details: nil
        )
      )
      return
    }

    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)

    // Required on iPad - presenting a popover without an anchor raises.
    if let popover = activity.popoverPresentationController {
      popover.sourceView = controller.view
      popover.sourceRect = CGRect(
        x: controller.view.bounds.midX,
        y: controller.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }

    controller.present(activity, animated: true) {
      result(nil)
    }
  }
}
