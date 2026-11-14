import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var notify: NotifyBridge?

  /// Taps that arrived before the Flutter engine existed. With the scene
  /// lifecycle the engine is built when a scene connects, which is after a
  /// tap that launched the app has already been delivered here.
  private var pendingClicks: [[String: String]] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before super, and before the engine exists: a tap that launched the
    // app is delivered once a delegate is set, and is lost if none is.
    UNUserNotificationCenter.current().delegate = self

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
    let bridge = NotifyBridge(messenger: engineBridge.applicationRegistrar.messenger())
    notify = bridge
    let waiting = pendingClicks
    pendingClicks = []
    waiting.forEach(bridge.deliver)
  }

  // MARK: APNs

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    notify?.token(deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    NSLog("[loaf push] APNs registration failed: \(error)")
    notify?.token(nil)
  }

  // MARK: UNUserNotificationCenterDelegate

  /// Nothing while the app is in front: the notifier and the chime handle
  /// what arrives then, and a banner over the conversation you are reading
  /// is noise.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    // The extension writes roomId/eventId; when it did not run, the
    // gateway's own top-level keys are what is there.
    let roomId = (info["roomId"] ?? info["room_id"]) as? String
    let eventId = (info["eventId"] ?? info["event_id"]) as? String
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let roomId, let eventId
    else {
      completionHandler()
      return
    }
    let click = ["roomId": roomId, "eventId": eventId]
    DispatchQueue.main.async {
      if let notify = self.notify {
        notify.deliver(click)
      } else {
        self.pendingClicks.append(click)
      }
      completionHandler()
    }
  }
}
