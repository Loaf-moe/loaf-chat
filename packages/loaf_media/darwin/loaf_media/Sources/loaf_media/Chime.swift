import AudioToolbox
import Foundation

/// The chime, played with System Sound Services: Apple's player for short
/// alert sounds. On iOS it never sounds while the ring/silent switch is on
/// silent, whatever else the app is playing, and it never touches the
/// app's audio session, so it mixes with other apps' audio rather than
/// interrupting it. It plays at the alert volume.
final class Chime {
  private let path: (String) -> String?

  /// Registered once per asset and kept for the app's life: registering is
  /// the slow part, and there is only the one sound.
  private var sounds: [String: SystemSoundID] = [:]

  /// [path] turns a Flutter asset key into a file in the app bundle.
  init(path: @escaping (String) -> String?) {
    self.path = path
  }

  enum Failure: Error {
    case missing(String)
    case unplayable(OSStatus)
  }

  func play(asset: String) throws {
    let sound: SystemSoundID
    if let known = sounds[asset] {
      sound = known
    } else {
      guard let file = path(asset) else { throw Failure.missing(asset) }
      var id: SystemSoundID = 0
      let status = AudioServicesCreateSystemSoundID(
        URL(fileURLWithPath: file) as CFURL, &id)
      guard status == kAudioServicesNoError else { throw Failure.unplayable(status) }
      sounds[asset] = id
      sound = id
    }
    // Not AudioServicesPlayAlertSound: that one also vibrates an iPhone.
    AudioServicesPlaySystemSound(sound)
  }
}
