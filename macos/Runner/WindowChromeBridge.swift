import Cocoa
import FlutterMacOS

/// Hides the system's title bar and buttons, and does what Loaf's own ask
/// for over `loaf/window`. The window stays `.titled`, so it keeps its
/// shadow, rounded corners, resize edges and native fullscreen.
final class WindowChromeBridge: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "loaf/window", binaryMessenger: messenger)
    super.init()
    Self.hideTitleBar(of: window)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let names: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didResizeNotification,
    ]
    for name in names {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in self?.sendState() })
    }
    // The will* notifications fire before styleMask flips, so the state they
    // send says what is about to be true; the did* ones then confirm it.
    let transitions: [(Notification.Name, Bool)] = [
      (NSWindow.willEnterFullScreenNotification, true),
      (NSWindow.willExitFullScreenNotification, false),
    ]
    for (name, fullscreen) in transitions {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in self?.sendState(fullscreen: fullscreen) })
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  private static func hideTitleBar(of window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = true
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let window else {
      result(nil)
      return
    }
    switch call.method {
    case "state":
      result(state(of: window))
    case "minimize":
      window.miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      window.zoom(nil)
      result(nil)
    case "close":
      // Through the close path, so the delegate's quit-after-last-window
      // rule still applies.
      window.performClose(nil)
      result(nil)
    case "startDrag":
      // Called from Flutter's pan start, inside a live mouse drag.
      if let event = window.currentEvent {
        window.performDrag(with: event)
      }
      result(nil)
    case "titlebarDoubleClick":
      doubleClick(window)
      result(nil)
    case "setMaxButtonRect":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state(of window: NSWindow, fullscreen: Bool? = nil) -> [String: Any] {
    [
      "maximized": window.isZoomed,
      "fullscreen": fullscreen ?? window.styleMask.contains(.fullScreen),
      "focused": window.isKeyWindow,
    ]
  }

  private func sendState(fullscreen: Bool? = nil) {
    guard let window else { return }
    channel.invokeMethod("stateChanged", arguments: state(of: window, fullscreen: fullscreen))
  }

  /// Does what the person set in System Settings › Desktop & Dock for a
  /// title bar double-click: zoom (the default), minimize, or nothing.
  private func doubleClick(_ window: NSWindow) {
    let defaults = UserDefaults.standard
    switch defaults.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      window.miniaturize(nil)
    case "None":
      break
    case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
      window.miniaturize(nil)
    default:
      window.zoom(nil)
    }
  }
}
