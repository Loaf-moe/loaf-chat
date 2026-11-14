import Flutter
import UIKit
import UserNotifications

/// The iOS end of `moe.loaf.chat/notify`, the other end being
/// `lib/push/ios_push.dart`. It shares the channel with macOS's bridge
/// because both drive the same UNUserNotificationCenter; what is iOS's
/// alone is the APNs token, and a withdraw that can take back only part of
/// a room.
///
/// It is NOT the UNUserNotificationCenter delegate: this app adopts the
/// scene lifecycle, so the Flutter engine — and therefore this object —
/// exists only once a scene connects, which is after a tap that launched
/// the app has already been delivered. AppDelegate takes the delegate role
/// before then and hands anything it caught to `deliver`.
final class NotifyBridge: NSObject {
  private let channel: FlutterMethodChannel
  private let center = UNUserNotificationCenter.current()

  /// Clicks from before Dart listened: a tap on a notification left from
  /// the last run launches the app, and arrives before the shell is up.
  private var held: [[String: String]] = []
  private var ready = false

  /// The pushToken call waiting on APNs, and the deadline that answers it
  /// if APNs never does.
  private var pendingToken: FlutterResult?
  private var tokenDeadline: DispatchWorkItem?

  /// APNs takes as long as the network does; past this the app carries on
  /// without push rather than hanging the sign-in behind it.
  private static let tokenTimeout: TimeInterval = 20

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "moe.loaf.chat/notify", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "prepare": self.prepare(result)
      case "pushToken": self.pushToken(result)
      case "withdraw":
        self.withdraw(
          args["roomId"] as? String ?? "", before: args["before"] as? Int, result)
      case "blocked": self.blocked(result)
      case "openSettings":
        self.openSettings()
        result(nil)
      case "ready":
        self.ready = true
        let waiting = self.held
        self.held = []
        waiting.forEach { self.channel.invokeMethod("click", arguments: $0) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: what AppDelegate hands over

  /// A tap, from whenever it happened. Held until Dart says it is listening.
  func deliver(_ click: [String: String]) {
    if ready {
      channel.invokeMethod("click", arguments: click)
    } else {
      held.append(click)
    }
  }

  /// The APNs answer, hex or nil. Anything after the first is ignored: the
  /// result has already been sent.
  func token(_ hex: String?) {
    guard let pending = pendingToken else { return }
    pendingToken = nil
    tokenDeadline?.cancel()
    tokenDeadline = nil
    pending(hex)
  }

  // MARK: channel methods

  private func prepare(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
        if let error { NSLog("[loaf notify] permission: \(error)") }
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  private func pushToken(_ result: @escaping FlutterResult) {
    // A second caller while one is outstanding gets nil rather than
    // displacing it; the first answer is the one that matters.
    guard pendingToken == nil else {
      result(nil)
      return
    }
    pendingToken = result
    let deadline = DispatchWorkItem { [weak self] in self?.token(nil) }
    tokenDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tokenTimeout, execute: deadline)
    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
  }

  /// [before] is milliseconds since the epoch: only what arrived earlier is
  /// taken back, so reading up to a point leaves the rest standing.
  private func withdraw(_ roomId: String, before: Int?, _ result: @escaping FlutterResult) {
    let cutoff = before.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    center.getDeliveredNotifications { delivered in
      let ids =
        delivered
        .filter { $0.request.content.threadIdentifier == roomId }
        .filter { notification in
          guard let cutoff else { return true }
          return notification.date < cutoff
        }
        .map(\.request.identifier)
      self.center.removeDeliveredNotifications(withIdentifiers: ids)
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func blocked(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      DispatchQueue.main.async { result(settings.authorizationStatus == .denied) }
    }
  }

  private func openSettings() {
    let path: String
    if #available(iOS 16.0, *) {
      path = UIApplication.openNotificationSettingsURLString
    } else {
      path = UIApplication.openSettingsURLString
    }
    guard let url = URL(string: path) else { return }
    UIApplication.shared.open(url)
  }
}
