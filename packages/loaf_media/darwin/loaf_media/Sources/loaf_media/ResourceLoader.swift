import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Why a player could not be made.
enum VideoError: Error, CustomStringConvertible {
  case badURL(String)

  var description: String {
    switch self {
    case .badURL(let id): return "no loaf-media URL for \(id)"
    }
  }
}

/// AVFoundation's hook for bytes it cannot fetch itself. A `loaf-media:`
/// URL has no handler of its own, so every request for it comes here and is
/// answered from the growing file as the download reaches it.
final class ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  private let stream: VideoStream
  private let contentType: String

  private init(stream: VideoStream, mimeType: String?) {
    self.stream = stream
    contentType =
      mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
  }

  /// An asset for file [id] whose bytes come through a new loader. The
  /// asset holds its delegate weakly, so the caller keeps the loader.
  static func asset(id: String, mimeType: String?) throws -> (AVURLAsset, ResourceLoader) {
    // The id goes in the path: it is promised safe in a path segment, and
    // a host would refuse a name with a space in it.
    var components = URLComponents()
    components.scheme = "loaf-media"
    components.host = ""
    components.path = "/" + id
    guard let url = components.url else { throw VideoError.badURL(id) }
    let stream = VideoStreams.shared.stream(id)
    let loader = ResourceLoader(stream: stream, mimeType: mimeType)
    let asset = AVURLAsset(url: url)
    asset.resourceLoader.setDelegate(loader, queue: stream.queue)
    return (asset, loader)
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    stream.add(loadingRequest, contentType: contentType)
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    stream.cancel(loadingRequest)
  }
}
