import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // This app adopts the UIScene lifecycle (Info.plist's
    // UIApplicationSceneManifest), so UIKit never calls
    // applicationDidEnterBackground here. Overriding the scene callback on
    // SceneDelegate is not the answer either: FlutterSceneDelegate implements
    // those to forward to plugins without declaring them in its header, so a
    // Swift override would quietly take that forwarding away. The scene's
    // notification is neither, and there is only one scene
    // (UIApplicationSupportsMultipleScenes is false).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(holdOpenForDatabaseWrites),
      name: UIScene.didEnterBackgroundNotification,
      object: nil
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// iOS kills an app that is suspended while it still holds a lock on a file
  /// in a shared container — `0xdead10cc`. This keeps us alive a few seconds
  /// past backgrounding so the SDK's in-flight writes commit and no
  /// transaction is open against the App Group database when we are suspended.
  @objc private func holdOpenForDatabaseWrites() {
    let application = UIApplication.shared
    var task = UIBackgroundTaskIdentifier.invalid
    task = application.beginBackgroundTask(withName: "loaf.db") {
      guard task != .invalid else { return }
      application.endBackgroundTask(task)
      task = .invalid
    }
    guard task != .invalid else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard task != .invalid else { return }
      application.endBackgroundTask(task)
      task = .invalid
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
