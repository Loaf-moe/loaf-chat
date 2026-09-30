import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var updaterBridge: UpdaterBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setFrame(Self.initialFrame(around: self.frame), display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    updaterBridge = UpdaterBridge(
      messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// Opens wide enough for the desktop layout. The template's 800pt sits
  /// under the shell's 900pt breakpoint, so every launch showed the phone
  /// layout. Shrinks to fit smaller screens, and stays resizable down to
  /// phone width, which is how the phone layout gets checked on a Mac.
  private static func initialFrame(around frame: NSRect) -> NSRect {
    let preferred = NSSize(width: 1280, height: 800)
    guard let visible = NSScreen.main?.visibleFrame else {
      return NSRect(origin: frame.origin, size: preferred)
    }
    let size = NSSize(
      width: min(preferred.width, visible.width),
      height: min(preferred.height, visible.height)
    )
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2
    )
    return NSRect(origin: origin, size: size)
  }
}
