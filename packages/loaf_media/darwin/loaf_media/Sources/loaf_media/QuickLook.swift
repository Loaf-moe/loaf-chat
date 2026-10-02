import QuickLook

#if os(iOS)
  import UIKit

  /// Quick Look on iOS: a `QLPreviewController` presented over whatever is
  /// on screen. It brings its own pinch zoom, swipe to close and share
  /// sheet, with Save Image and Save to Files.
  final class QuickLook {
    /// The controller holds its data source weakly; this keeps it alive.
    private var items: PreviewItems?

    func show(_ url: URL) throws {
      guard let top = Self.topViewController() else { throw QuickLookError.noWindow }
      let items = PreviewItems(url: url)
      self.items = items
      let controller = QLPreviewController()
      controller.dataSource = items
      top.present(controller, animated: true)
    }

    /// The view controller on top in the active scene's key window: the
    /// root, then whatever it presents, all the way up.
    private static func topViewController() -> UIViewController? {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
      var top = scene?.keyWindow?.rootViewController
      while let presented = top?.presentedViewController {
        top = presented
      }
      return top
    }
  }

  private final class PreviewItems: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) {
      self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(
      _ controller: QLPreviewController, previewItemAt index: Int
    ) -> QLPreviewItem {
      url as NSURL
    }
  }

#elseif os(macOS)
  import Cocoa
  import Quartz

  /// The shared panel's controller. QLPreviewPanel looks for one along the
  /// key window's responder chain, so this sits in that chain, just after
  /// the window, as AppKit means it to.
  final class QuickLookResponder: NSResponder, QLPreviewPanelDataSource {
    var url: URL?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
      panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
      panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
      url as NSURL?
    }
  }

  /// Quick Look on macOS: Finder's own floating panel.
  final class QuickLook {
    private let responder = QuickLookResponder()

    /// The window whose chain [responder] is in.
    private weak var window: NSWindow?

    func show(_ url: URL) throws {
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        throw QuickLookError.noWindow
      }
      adopt(window)
      responder.url = url
      guard let panel = QLPreviewPanel.shared() else { throw QuickLookError.noPanel }
      panel.reloadData()
      panel.makeKeyAndOrderFront(nil)
    }

    /// Puts [responder] after [window] in its chain, once per window.
    private func adopt(_ window: NSWindow) {
      if self.window === window { return }
      // Out of the old window's chain first, so it is never in two.
      if let old = self.window, old.nextResponder === responder {
        old.nextResponder = responder.nextResponder
      }
      responder.nextResponder = window.nextResponder
      window.nextResponder = responder
      self.window = window
    }
  }
#endif
