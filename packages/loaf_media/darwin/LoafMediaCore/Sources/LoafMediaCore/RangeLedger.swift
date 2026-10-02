/// How far a download has got, as Dart last reported it. The bytes before
/// `received` are on disk and never change.
public struct StreamProgress: Equatable {
  public var received: Int64
  /// Known once the server says, or from the sender's `info.size`.
  public var total: Int64?
  public var complete: Bool
  public var failed: Bool

  public init(received: Int64, total: Int64?, complete: Bool, failed: Bool) {
    self.received = received
    self.total = total
    self.complete = complete
    self.failed = failed
  }
}

public enum LedgerStep: Equatable {
  /// Read these bytes from the file and hand them over.
  case respond(offset: Int64, length: Int)
  /// The request is satisfied.
  case finish
  /// Nothing new yet.
  case wait
  case fail
}

/// What to do next for one data request, given how far the download is.
/// A nil `requestedLength` asks for everything to the end of the resource.
public func nextStep(
  requestedOffset: Int64, requestedLength: Int64?, currentOffset: Int64,
  progress: StreamProgress, maxChunk: Int = 256 * 1024
) -> LedgerStep {
  // A failed download sends nothing more, even bytes it already had: the
  // player is told now rather than stalling at the gap later.
  if progress.failed { return .fail }
  let end = requestedLength.map { requestedOffset + $0 }
  if let end, currentOffset >= end { return .finish }
  if currentOffset < progress.received {
    let available = min(end ?? progress.received, progress.received) - currentOffset
    return .respond(offset: currentOffset, length: Int(min(available, Int64(maxChunk))))
  }
  // Past what has arrived: only a finished download can say there is no more.
  return progress.complete ? .finish : .wait
}
