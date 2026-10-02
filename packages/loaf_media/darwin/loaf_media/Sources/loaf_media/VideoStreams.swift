import AVFoundation
import Foundation
import LoafMediaCore

/// The downloads players are reading, by file id. Dart reports each one's
/// progress over the channel (`stream.begin`, `stream.progress`,
/// `stream.end`); the other end is `lib/src/streams.dart`.
final class VideoStreams {
  static let shared = VideoStreams()

  private let lock = NSLock()
  private var streams: [String: VideoStream] = [:]

  /// The stream for [id], made empty if Dart has not begun it yet: the
  /// view can be created before `stream.begin` arrives, and its requests
  /// then wait for the progress that follows.
  func stream(_ id: String) -> VideoStream {
    lock.lock()
    defer { lock.unlock() }
    if let stream = streams[id] { return stream }
    let stream = VideoStream(id: id)
    streams[id] = stream
    return stream
  }

  func begin(id: String, path: String, progress: StreamProgress) {
    stream(id).begin(path: path, progress: progress)
  }

  func progress(id: String, progress: StreamProgress) {
    stream(id).update(progress)
  }

  func end(id: String) {
    lock.lock()
    let stream = streams.removeValue(forKey: id)
    lock.unlock()
    stream?.end()
  }
}

/// One growing file and the player requests waiting on it. Everything here
/// runs on [queue], which is also the resource loader's delegate queue, so
/// requests, progress and cancellations arrive in one order.
final class VideoStream {
  let queue: DispatchQueue

  private var path: String?
  private var progress = StreamProgress(received: 0, total: nil, complete: false, failed: false)

  /// Opened on the first read and kept: the download renames `<name>.part`
  /// to `<name>` when it completes, and an open descriptor follows the file
  /// through the rename where a path would not.
  private var file: FileHandle?
  private var pending: [Pending] = []

  private struct Pending {
    let request: AVAssetResourceLoadingRequest
    let contentType: String
  }

  init(id: String) {
    queue = DispatchQueue(label: "moe.loaf.chat.media.stream.\(id)")
  }

  /// Also called again after a failed download is retried: it writes a new
  /// `.part`, so the old descriptor is let go and the next read opens the
  /// new one. The bytes are the same file's, so waiting requests carry on.
  func begin(path: String, progress: StreamProgress) {
    queue.async {
      self.closeFile()
      self.path = path
      self.progress = progress
      self.serve()
    }
  }

  func update(_ progress: StreamProgress) {
    queue.async {
      self.progress = progress
      self.serve()
    }
  }

  /// Nobody is playing the file any more. Anything still waiting fails
  /// rather than hanging.
  func end() {
    queue.async {
      self.progress.failed = true
      self.serve()
      self.closeFile()
    }
  }

  /// From the resource loader, on [queue].
  func add(_ request: AVAssetResourceLoadingRequest, contentType: String) {
    dispatchPrecondition(condition: .onQueue(queue))
    pending.append(Pending(request: request, contentType: contentType))
    serve()
  }

  /// From the resource loader, on [queue].
  func cancel(_ request: AVAssetResourceLoadingRequest) {
    dispatchPrecondition(condition: .onQueue(queue))
    pending.removeAll { $0.request === request }
  }

  private enum Outcome {
    case done
    case waiting
    case progressed
  }

  /// Answers what can be answered now. Each request gets at most one chunk
  /// per pass, and another pass is queued behind any cancellations, so a
  /// long read never holds the queue while the player is seeking elsewhere.
  private func serve() {
    var progressed = false
    pending.removeAll { entry in
      switch serve(entry) {
      case .done: return true
      case .waiting: return false
      case .progressed:
        progressed = true
        return false
      }
    }
    if progressed {
      queue.async { self.serve() }
    }
  }

  private func serve(_ entry: Pending) -> Outcome {
    let request = entry.request
    if request.isCancelled || request.isFinished { return .done }
    if progress.failed {
      request.finishLoading(with: Self.failure)
      return .done
    }

    if let info = request.contentInformationRequest, info.contentType == nil {
      // The player cannot be told the length until the server has said.
      guard let total = progress.total else { return .waiting }
      info.contentType = entry.contentType
      info.contentLength = total
      info.isByteRangeAccessSupported = true
    }

    guard let data = request.dataRequest else {
      request.finishLoading()
      return .done
    }

    let step = nextStep(
      requestedOffset: data.requestedOffset,
      requestedLength: data.requestsAllDataToEndOfResource ? nil : Int64(data.requestedLength),
      currentOffset: data.currentOffset,
      progress: progress)
    switch step {
    case .respond(let offset, let length):
      guard let bytes = read(offset: offset, length: length) else {
        request.finishLoading(with: Self.failure)
        return .done
      }
      data.respond(with: bytes)
      return .progressed
    case .finish:
      request.finishLoading()
      return .done
    case .fail:
      request.finishLoading(with: Self.failure)
      return .done
    case .wait:
      return .waiting
    }
  }

  /// The bytes at [offset], all of which have arrived. Nil if the file
  /// cannot be read, or holds less than Dart said it does.
  private func read(offset: Int64, length: Int) -> Data? {
    do {
      guard let file = try openFile() else { return nil }
      try file.seek(toOffset: UInt64(offset))
      guard let bytes = try file.read(upToCount: length), !bytes.isEmpty else { return nil }
      return bytes
    } catch {
      NSLog("[loaf media] couldn't read \(path ?? "a stream"): \(error)")
      return nil
    }
  }

  private func openFile() throws -> FileHandle? {
    if let file { return file }
    guard let path else { return nil }
    let opened: FileHandle
    do {
      opened = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } catch {
      // Finished between Dart's report and this read: renamed off `.part`.
      guard path.hasSuffix(".part") else { throw error }
      opened = try FileHandle(forReadingFrom: URL(fileURLWithPath: String(path.dropLast(5))))
    }
    file = opened
    return opened
  }

  private func closeFile() {
    try? file?.close()
    file = nil
  }

  private static let failure = NSError(
    domain: "moe.loaf.chat.media", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "the download failed"])
}
