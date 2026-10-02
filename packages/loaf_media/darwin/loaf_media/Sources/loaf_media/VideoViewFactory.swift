import AVFoundation
import AVKit

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// One inline player: the asset reading the growing file, and the player
/// Dart can pause. Says over the channel when it starts playing, so Dart
/// can pause whichever was playing before.
final class InlineVideo {
  let player: AVPlayer
  private let loader: ResourceLoader?
  private var status: NSKeyValueObservation?

  init(view: Int64, id: String, mimeType: String?, channel: FlutterMethodChannel) {
    do {
      let (asset, loader) = try ResourceLoader.asset(id: id, mimeType: mimeType)
      self.loader = loader
      player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    } catch {
      // A view must be returned whatever happens; this one plays nothing.
      NSLog("[loaf media] no player for \(id): \(error)")
      loader = nil
      player = AVPlayer()
    }
    status = player.observe(\.timeControlStatus) { [weak channel] player, _ in
      guard player.timeControlStatus == .playing else { return }
      DispatchQueue.main.async {
        channel?.invokeMethod("video.playing", arguments: ["view": view])
      }
    }
  }

  func pause() {
    player.pause()
  }

  /// When the view goes: nothing keeps playing or reading behind it.
  func tearDown() {
    player.pause()
    status?.invalidate()
    status = nil
    player.replaceCurrentItem(with: nil)
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
  final class InlineVideoView: NSObject, FlutterPlatformView {
    let box: VideoBox
    private let controller = AVPlayerViewController()

    init(video: InlineVideo, parent: UIViewController?) {
      box = VideoBox(video)
      super.init()
      controller.player = video.player
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
