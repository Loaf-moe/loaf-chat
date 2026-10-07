#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif
import LoafMediaCore

/// The native half of `package:loaf_media`: Quick Look, on macOS the
/// default app, the clipboard's pictures and files, and the inline video
/// player. The other ends are
/// `lib/src/native.dart`, `lib/src/streams.dart` and `lib/src/video.dart`.
public final class LoafMediaPlugin: NSObject, FlutterPlugin {
  private let quickLook = QuickLook()
  private let videos: VideoViewFactory

  private init(videos: VideoViewFactory) {
    self.videos = videos
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: "moe.loaf.chat/media", binaryMessenger: messenger)
    #if os(iOS)
      let videos = VideoViewFactory(channel: channel, registrar: registrar)
    #else
      let videos = VideoViewFactory(channel: channel)
    #endif
    registrar.addMethodCallDelegate(LoafMediaPlugin(videos: videos), channel: channel)
    registrar.register(videos, withId: "moe.loaf.chat/video")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "clipboard.has":
      result(Clipboard.hasFiles())
    case "clipboard.files":
      result(Clipboard.files())
    case "clipboard.image":
      result(Clipboard.png().map { FlutterStandardTypedData(bytes: $0) })
    case "stream.begin":
      guard let id = arguments?["id"] as? String, let path = arguments?["path"] as? String,
        let progress = Self.progress(arguments)
      else {
        result(Self.badArguments(call))
        return
      }
      VideoStreams.shared.begin(id: id, path: path, progress: progress)
      result(nil)
    case "stream.progress":
      guard let id = arguments?["id"] as? String, let progress = Self.progress(arguments) else {
        result(Self.badArguments(call))
        return
      }
      VideoStreams.shared.progress(id: id, progress: progress)
      result(nil)
    case "stream.end":
      guard let id = arguments?["id"] as? String else {
        result(Self.badArguments(call))
        return
      }
      VideoStreams.shared.end(id: id)
      result(nil)
    case "video.pause":
      guard let view = (arguments?["view"] as? NSNumber)?.int64Value else {
        result(Self.badArguments(call))
        return
      }
      videos.pause(view: view)
      result(nil)
    case "video.stopAll":
      videos.stopAll()
      result(nil)
    case "video.floating":
      guard let view = (arguments?["view"] as? NSNumber)?.int64Value else {
        result(Self.badArguments(call))
        return
      }
      #if os(iOS)
        result(InlineVideoView.isFloating(view: view))
      #else
        result(false)
      #endif
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

  /// A download's progress as `stream.begin` and `stream.progress` carry it.
  private static func progress(_ arguments: [String: Any]?) -> StreamProgress? {
    guard let received = (arguments?["received"] as? NSNumber)?.int64Value,
      let complete = arguments?["complete"] as? Bool,
      let failed = arguments?["failed"] as? Bool
    else { return nil }
    let total = (arguments?["total"] as? NSNumber)?.int64Value
    return StreamProgress(received: received, total: total, complete: complete, failed: failed)
  }

  private static func badArguments(_ call: FlutterMethodCall) -> FlutterError {
    FlutterError(code: "bad-arguments", message: "\(call.method) without what it needs", details: nil)
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
