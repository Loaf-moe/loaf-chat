/// Where one player is in picture in picture.
public struct PictureInPicture: Equatable {
  public enum State: Equatable {
    case idle
    case starting
    case active
  }

  public enum Event: Equatable {
    case willStart
    case didStart
    case failedToStart
    case didStop
  }

  public private(set) var state: State = .idle

  public init() {}

  /// Whether the player must outlive its row. It is kept from the moment
  /// picture in picture begins starting: the row can go while it animates.
  public var keepsPlayer: Bool { state != .idle }

  /// Moves on with [event]. Returns what to tell Dart, `true` for active
  /// and `false` for over, or nil when there is nothing new to say. A stop
  /// or failure with nothing starting or active is a no-op, so AVKit
  /// repeating itself never sends anything twice.
  public mutating func handle(_ event: Event) -> Bool? {
    switch (state, event) {
    case (.idle, .willStart):
      state = .starting
      return nil
    case (.idle, .didStart), (.starting, .didStart):
      state = .active
      return true
    case (.starting, .failedToStart), (.starting, .didStop),
      (.active, .failedToStart), (.active, .didStop):
      // From starting, Dart never heard `true`; `false` then is harmless,
      // and it settles any player Dart left waiting on the answer.
      state = .idle
      return false
    default:
      return nil
    }
  }
}
