#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

/// The native half of `package:loaf_media`: Quick Look, and on macOS the
/// default app. The other end is `lib/src/native.dart`.
public final class LoafMediaPlugin: NSObject, FlutterPlugin {
  private let quickLook = QuickLook()

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: "moe.loaf.chat/media", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(LoafMediaPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "quickLook":
      guard let path = arguments?["path"] as? String else {
        result(Self.failure("no path to look at"))
        return
      }
      do {
        try quickLook.show(URL(fileURLWithPath: path))
        result(nil)
      } catch {
        result(Self.failure("\(error)"))
      }
    #if os(macOS)
      case "defaultAppName":
        guard let pathExtension = arguments?["extension"] as? String else {
          result(Self.failure("no extension to look up"))
          return
        }
        result(DefaultApp.name(forExtension: pathExtension))
      case "openWithDefaultApp":
        guard let path = arguments?["path"] as? String else {
          result(Self.failure("no path to open"))
          return
        }
        guard DefaultApp.open(URL(fileURLWithPath: path)) else {
          result(Self.failure("no app would open \(path)"))
          return
        }
        result(nil)
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func failure(_ message: String) -> FlutterError {
    FlutterError(code: "open-failed", message: message, details: nil)
  }
}

/// Why Quick Look could not be shown.
enum QuickLookError: Error, CustomStringConvertible {
  case noWindow
  case noPanel

  var description: String {
    switch self {
    case .noWindow: return "no window to show Quick Look from"
    case .noPanel: return "the Quick Look panel is unavailable"
    }
  }
}
