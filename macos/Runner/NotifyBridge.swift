import Cocoa
import FlutterMacOS
import Intents
import UserNotifications

/// Desktop notifications on macOS. Each message is donated as an incoming
/// INSendMessageIntent, so it shows as a communication notification with
/// the sender's picture. That needs Apple's communication entitlement:
/// debug builds carry it through their development profile, releases get
/// it at signing (`tool/release/macos.sh`). Without it the update fails and
/// the plain notification goes. The other end is
/// `lib/notify/channel_notifications.dart`.
final class NotifyBridge: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private let center = UNUserNotificationCenter.current()

  /// Clicks from before Dart listened: a click on a notification left from
  /// the last run launches the app, and arrives before the shell is up.
  private var held: [[String: String]] = []
  private var ready = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "moe.loaf.chat/notify", binaryMessenger: messenger)
    super.init()
    // Made from awakeFromNib, before launch finishes: early enough for the
    // click that launched the app.
    center.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "prepare": self.prepare(result)
      case "show": self.show(args, result)
      case "withdraw": self.withdraw(args["roomId"] as? String ?? "", result)
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

  private func prepare(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      self.center.requestAuthorization(options: [.alert, .sound]) { _, error in
        if let error { NSLog("[loaf notify] permission: \(error)") }
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  private func show(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let roomId = args["roomId"] as? String, let eventId = args["eventId"] as? String
    else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = args["title"] as? String ?? ""
    content.body = args["body"] as? String ?? ""
    content.threadIdentifier = roomId
    content.userInfo = ["roomId": roomId, "eventId": eventId]
    let sound = args["sound"] as? Bool ?? false
    if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("chime.wav")) }

    let intent = Self.intent(args, roomId: roomId)
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate { error in
      if let error { NSLog("[loaf notify] donate: \(error)") }
      let shown: UNNotificationContent
      do {
        shown = try content.updating(from: intent)
      } catch {
        NSLog("[loaf notify] plain notification: \(error)")
        shown = content
      }
      // Withdrawn by this prefix: an updated content may not keep the
      // thread id.
      let request = UNNotificationRequest(
        identifier: "\(roomId)|\(eventId)", content: shown, trigger: nil)
      self.center.add(request) { error in
        if let error { NSLog("[loaf notify] \(error)") }
        DispatchQueue.main.async { result(sound) }
      }
    }
  }

  private static func intent(_ args: [String: Any], roomId: String) -> INSendMessageIntent {
    let senderId = args["senderId"] as? String ?? ""
    let image = (args["avatarPath"] as? String)
      .flatMap { FileManager.default.contents(atPath: $0) }
      .map { INImage(imageData: $0) }
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: args["sender"] as? String,
      image: image,
      contactIdentifier: nil,
      customIdentifier: senderId)
    let place = args["place"] as? String
    // The sender's picture rides on the INPerson: setImage(_:forParameterNamed:)
    // is unavailable on macOS.
    return INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: args["body"] as? String,
      speakableGroupName: place.map { INSpeakableString(spokenPhrase: $0) },
      conversationIdentifier: roomId,
      serviceName: nil,
      sender: sender,
      attachments: nil)
  }

  private func withdraw(_ roomId: String, _ result: @escaping FlutterResult) {
    center.getDeliveredNotifications { delivered in
      let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix("\(roomId)|") }
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
    let id = Bundle.main.bundleIdentifier ?? ""
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: UNUserNotificationCenterDelegate

  /// Dart shows one only while the app is not in front. If it is in front
  /// by the time this one lands, show it anyway: it was asked for.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let roomId = info["roomId"] as? String, let eventId = info["eventId"] as? String
    else {
      completionHandler()
      return
    }
    let click = ["roomId": roomId, "eventId": eventId]
    DispatchQueue.main.async {
      if self.ready {
        self.channel.invokeMethod("click", arguments: click)
      } else {
        self.held.append(click)
      }
      completionHandler()
    }
  }
}
