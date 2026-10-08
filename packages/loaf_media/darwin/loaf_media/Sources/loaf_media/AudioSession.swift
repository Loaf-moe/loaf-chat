#if os(iOS)
  import AVFoundation
  import LoafMediaCore

  /// Holds the audio session while an inline video plays with its sound on.
  /// The app's default session mutes on the silent switch and cannot do
  /// picture in picture; video needs `.playback`. It is claimed only for as
  /// long as it is needed, so other sounds keep their own behaviour and
  /// other apps' audio resumes when the video stops. Main thread only.
  final class AudioSession {
    static let shared = AudioSession()

    private var claim = AudioClaim()

    private init() {}

    func report(view: Int64, playing: Bool, muted: Bool) {
      apply(claim.update(view: view, playing: playing, muted: muted))
    }

    func remove(view: Int64) {
      apply(claim.remove(view: view))
    }

    private func apply(_ transition: AudioClaim.Transition?) {
      let session = AVAudioSession.sharedInstance()
      switch transition {
      case .claim:
        do {
          try session.setCategory(.playback, mode: .moviePlayback)
          try session.setActive(true)
        } catch {
          NSLog("[loaf media] couldn't claim the audio session: \(error)")
        }
      case .release:
        do {
          try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
          NSLog("[loaf media] couldn't release the audio session: \(error)")
        }
      case nil:
        break
      }
    }
  }
#endif
