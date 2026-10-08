import AVFoundation
import AVKit
import LoafMediaCore

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// One inline player: the asset reading the growing file, and the player
/// Dart can pause. Tells Dart over the channel when its item can play (or
/// never will), and when it starts playing, so Dart can drop its download
/// progress and pause whichever video was playing before.
final class InlineVideo {
  let view: Int64
  let player: AVPlayer
  private let channel: FlutterMethodChannel
  private let loader: ResourceLoader?
  private var playing: NSKeyValueObservation?
  private var muting: NSKeyValueObservation?
  /// Whether the player was last known to be playing. Buffering keeps it,
  /// so a stall does not give up the audio session and take it back.
  private var wasPlaying = false
  private var readiness: NSKeyValueObservation?

  init(view: Int64, id: String, mimeType: String?, channel: FlutterMethodChannel) {
    self.view = view
    self.channel = channel
    let item: AVPlayerItem?
    do {
      let (asset, loader) = try ResourceLoader.asset(id: id, mimeType: mimeType)
      self.loader = loader
      item = AVPlayerItem(asset: asset)
    } catch {
      NSLog("[loaf media] no player for \(id): \(error)")
      loader = nil
      item = nil
    }
    player = AVPlayer(playerItem: item)
    playing = player.observe(\.timeControlStatus) { [weak self] player, _ in
      self?.reportAudio()
      guard player.timeControlStatus == .playing else { return }
      self?.send("video.playing")
    }
    // The player controls' own mute button changes this.
    muting = player.observe(\.isMuted) { [weak self] _, _ in
      self?.reportAudio()
    }
    guard let item else {
      // A view must be returned whatever happens; Dart offers Open instead.
      send("video.failed")
      return
    }
    // An index at the end of the file (an iPhone original) keeps the item
    // from being ready until the download reaches it; Dart shows the
    // download until then.
    readiness = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      switch item.status {
      case .readyToPlay: self?.send("video.ready")
      case .failed:
        NSLog("[loaf media] can't play: \(item.error.map { "\($0)" } ?? "no reason given")")
        self?.send("video.failed")
      default: break
      }
    }
  }

  /// Sent on the main thread, as the channel requires, and after the view's
  /// creation has been answered, so Dart already knows the view.
  func send(_ method: String, _ extra: [String: Any] = [:]) {
    let arguments = extra.merging(["view": view]) { mine, _ in mine }
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod(method, arguments: arguments)
    }
  }

  func pause() {
    player.pause()
  }

  /// Tells the audio session where this player stands, on the main thread.
  private func reportAudio() {
    #if os(iOS)
      switch player.timeControlStatus {
      case .playing: wasPlaying = true
      case .paused: wasPlaying = false
      default: break
      }
      let (view, playing, muted) = (view, wasPlaying, player.isMuted)
      if Thread.isMainThread {
        AudioSession.shared.report(view: view, playing: playing, muted: muted)
      } else {
        DispatchQueue.main.async {
          AudioSession.shared.report(view: view, playing: playing, muted: muted)
        }
      }
    #endif
  }

  /// When the view goes: nothing keeps playing or reading behind it.
  func tearDown() {
    player.pause()
    playing?.invalidate()
    playing = nil
    readiness?.invalidate()
    readiness = nil
    muting?.invalidate()
    muting = nil
    player.replaceCurrentItem(with: nil)
    #if os(iOS)
      // Removal, not a report: a stale report must not outlive the view.
      wasPlaying = false
      let view = view
      if Thread.isMainThread {
        AudioSession.shared.remove(view: view)
      } else {
        DispatchQueue.main.async { AudioSession.shared.remove(view: view) }
      }
    #endif
  }
}

/// Makes the `moe.loaf.chat/video` platform views, and finds them again for
/// `video.pause`. The views are held weakly: Flutter owns them.
final class VideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let channel: FlutterMethodChannel
  private let videos = NSMapTable<NSNumber, VideoBox>.strongToWeakObjects()

  #if os(iOS)
    private weak var registrar: FlutterPluginRegistrar?

    init(channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
      self.channel = channel
      self.registrar = registrar
    }
  #else
    init(channel: FlutterMethodChannel) {
      self.channel = channel
    }
  #endif

  func pause(view: Int64) {
    videos.object(forKey: NSNumber(value: view))?.video.pause()
  }

  /// Signing out: nothing of the account plays on. The rows go with it;
  /// a player floating in picture in picture has no row, so it is ended
  /// here.
  func stopAll() {
    for case let box as VideoBox in videos.objectEnumerator()?.allObjects ?? [] {
      box.video.pause()
    }
    #if os(iOS)
      InlineVideoView.stopFloating()
    #endif
  }

  // The two embedders disagree on whether a codec is optional.
  #if os(iOS)
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }
  #else
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
      FlutterStandardMessageCodec.sharedInstance()
    }
  #endif

  private func video(view: Int64, arguments: Any?) -> InlineVideo {
    let arguments = arguments as? [String: Any]
    let id = arguments?["id"] as? String ?? ""
    let mime = arguments?["mime"] as? String
    return InlineVideo(view: view, id: id, mimeType: mime, channel: channel)
  }

  #if os(iOS)
    func create(
      withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
      let view = InlineVideoView(
        video: video(view: viewId, arguments: args), parent: registrar?.viewController)
      videos.setObject(view.box, forKey: NSNumber(value: viewId))
      return view
    }
  #else
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
      let view = InlineVideoView(video: video(view: viewId, arguments: args))
      videos.setObject(view.box, forKey: NSNumber(value: viewId))
      return view
    }
  #endif
}

/// What the factory's weak table holds: alive exactly as long as its view.
final class VideoBox {
  let video: InlineVideo

  init(_ video: InlineVideo) {
    self.video = video
  }

  deinit {
    video.tearDown()
  }
}

#if os(iOS)
  /// AVPlayerViewController, embedded: its own controls, full screen,
  /// picture in picture and AirPlay. It sits in the view controller
  /// hierarchy as a child of Flutter's, as UIKit expects of an embedded
  /// controller, while Flutter places its view.
  final class InlineVideoView: NSObject, FlutterPlatformView, AVPlayerViewControllerDelegate {
    let box: VideoBox
    private let controller = AVPlayerViewController()

    /// Players in picture in picture keep themselves alive, by view id:
    /// the row may scroll away and be disposed while the video floats on,
    /// and letting go of the view then would end it. Released when it stops
    /// or fails to start.
    private static var floating: [Int64: InlineVideoView] = [:]
    private var pip = PictureInPicture()

    /// For Dart, as a row goes: whether this player lives on in picture in
    /// picture, starting or started, so its file must stay readable.
    static func isFloating(view: Int64) -> Bool {
      floating[view] != nil
    }

    /// Ends every floating player: with no player left to show, picture
    /// in picture closes, and the view is let go.
    static func stopFloating() {
      let views = Array(floating.values)
      floating.removeAll()
      for view in views {
        view.box.video.tearDown()
        view.controller.player = nil
      }
    }

    init(video: InlineVideo, parent: UIViewController?) {
      box = VideoBox(video)
      super.init()
      controller.player = video.player
      controller.delegate = self
      controller.entersFullScreenWhenPlaybackBegins = false
      controller.allowsPictureInPicturePlayback = true
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      if let parent {
        parent.addChild(controller)
        controller.didMove(toParent: parent)
      }
    }

    func view() -> UIView {
      controller.view
    }

    func playerViewControllerWillStartPictureInPicture(
      _ playerViewController: AVPlayerViewController
    ) {
      move(.willStart)
    }

    func playerViewControllerDidStartPictureInPicture(
      _ playerViewController: AVPlayerViewController
    ) {
      move(.didStart)
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      NSLog("[loaf media] picture in picture didn't start: \(error)")
      move(.failedToStart)
    }

    /// Back to the row if it is still on screen; if it has gone, there is
    /// nothing to restore into, and the video ends with the window.
    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
        @escaping (Bool) -> Void
    ) {
      completionHandler(controller.view.window != nil)
    }

    func playerViewControllerDidStopPictureInPicture(
      _ playerViewController: AVPlayerViewController
    ) {
      move(.didStop)
    }

    private func move(_ event: PictureInPicture.Event) {
      let report = pip.handle(event)
      let view = box.video.view
      if let report {
        box.video.send("video.pip", ["active": report])
      }
      // Last: when Flutter has already let go of the view, this lets the
      // player go too.
      Self.floating[view] = pip.keepsPlayer ? self : nil
    }

    deinit {
      // Flutter lets go of a platform view on the main thread.
      let controller = controller
      MainActor.assumeIsolated {
        controller.willMove(toParent: nil)
        controller.removeFromParent()
      }
    }
  }
#else
  /// AVPlayerView with its inline controls and the full-screen button.
  final class InlineVideoView: AVPlayerView {
    let box: VideoBox

    init(video: InlineVideo) {
      box = VideoBox(video)
      super.init(frame: .zero)
      controlsStyle = .inline
      showsFullScreenToggleButton = true
      player = video.player
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("not made from a nib")
    }
  }
#endif
