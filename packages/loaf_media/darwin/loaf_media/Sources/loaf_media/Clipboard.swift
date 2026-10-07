#if os(iOS)
  import UIKit
#elseif os(macOS)
  import Cocoa
#else
  #error("Unsupported platform.")
#endif

/// What the clipboard holds that is not text, for pasting into the composer:
/// a picture (a screenshot, "Copy Image"), and on macOS the files copied in
/// Finder. Flutter's own clipboard is text alone.
enum Clipboard {
  /// Whether there is a picture or a file to paste. It does not read them,
  /// so on iOS it does not raise the "Allow Paste" prompt that reading does.
  static func hasFiles() -> Bool {
    #if os(iOS)
      return UIPasteboard.general.hasImages
    #else
      return !files().isEmpty
        || NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    #endif
  }

  /// The paths of the regular files copied in Finder. iOS gives none: what
  /// it copies is a picture or text.
  static func files() -> [String] {
    #if os(macOS)
      let urls =
        NSPasteboard.general.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      return urls.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }.map { $0.path }
    #else
      return []
    #endif
  }

  /// The picture as PNG, or nil when there is none.
  static func png() -> Data? {
    #if os(iOS)
      return UIPasteboard.general.image?.pngData()
    #else
      guard let image = NSImage(pasteboard: NSPasteboard.general),
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
      else { return nil }
      return bitmap.representation(using: .png, properties: [:])
    #endif
  }
}
