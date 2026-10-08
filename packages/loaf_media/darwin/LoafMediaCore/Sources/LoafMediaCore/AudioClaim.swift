/// Which inline videos are making sound, so the audio session is held
/// exactly as long as one is.
public struct AudioClaim: Equatable {
  public enum Transition: Equatable {
    case claim
    case release
  }

  /// Views that are playing, and whether each is muted.
  private var playing: [Int64: Bool] = [:]

  public init() {}

  /// Whether some video is playing with its sound on.
  public var isClaimed: Bool { playing.values.contains(false) }

  /// Records [view]'s state. Returns what the session needs, or nil when
  /// nothing changed for it: only the first sound and the last silence
  /// matter, so the session is not touched on every status change.
  public mutating func update(view: Int64, playing isPlaying: Bool, muted: Bool) -> Transition? {
    let before = isClaimed
    playing[view] = isPlaying ? muted : nil
    return transition(from: before)
  }

  /// A view that is gone is not playing, whatever it last said.
  public mutating func remove(view: Int64) -> Transition? {
    let before = isClaimed
    playing[view] = nil
    return transition(from: before)
  }

  private func transition(from before: Bool) -> Transition? {
    switch (before, isClaimed) {
    case (false, true): return .claim
    case (true, false): return .release
    default: return nil
    }
  }
}
