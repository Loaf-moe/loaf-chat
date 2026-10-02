#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers

  /// The app Finder would open a file with, as Launch Services knows it.
  enum DefaultApp {
    /// Its name as Finder shows it, without `.app`; nil when nothing
    /// claims files ending in [pathExtension].
    static func name(forExtension pathExtension: String) -> String? {
      guard let type = UTType(filenameExtension: pathExtension),
        let app = NSWorkspace.shared.urlForApplication(toOpen: type)
      else { return nil }
      let name = FileManager.default.displayName(atPath: app.path)
      return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Opens [url] in its default app. False when nothing would.
    static func open(_ url: URL) -> Bool {
      NSWorkspace.shared.open(url)
    }
  }
#endif
