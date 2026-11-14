import Foundation
import LoafPushCore
import UserNotifications
import os

/// Decrypts and titles each push before iOS shows it. Reads what the app
/// left in the App Group; never writes, never refreshes the token. If it
/// runs out of time, iOS shows whatever alert the gateway sent.
final class NotificationService: UNNotificationServiceExtension {
  private static let log = Logger(subsystem: "moe.loaf.chat.ios.notify", category: "push")
  private var deliver: ((UNNotificationContent) -> Void)?
  private var best: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    deliver = contentHandler
    let out =
      (request.content.mutableCopy() as? UNMutableNotificationContent)
      ?? UNMutableNotificationContent()
    best = out
    let info = request.content.userInfo
    guard let roomId = info["room_id"] as? String, let eventId = info["event_id"] as? String,
      let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.moe.loaf.chat")
    else { return finish(out) }

    let settings = loadSettings(group.appendingPathComponent("notifications.json"))
    let names = loadNames(group.appendingPathComponent("names.json"))
    let store = Store(path: group.appendingPathComponent("loaf.sqlite").path)
    let cached = loadRules(group.appendingPathComponent("rules.json"))
    out.threadIdentifier = roomId
    out.userInfo = ["roomId": roomId, "eventId": eventId]
    out.sound =
      settings.sound ? UNNotificationSound(named: UNNotificationSoundName("chime.caf")) : nil

    Task {
      let session = store?.session()
      let (event, sender) = await Self.fetch(session, roomId: roomId, eventId: eventId)
      let power = await Self.state(session, roomId: roomId, type: "m.room.power_levels")
      // Stale or missing: ask the server, for this push only. Nothing in
      // the container is ever written from here.
      let rules =
        isStale(cached, now: Date())
        ? await Self.rules(session, keeping: cached) ?? cached
        : cached
      let shown = content(
        roomId: roomId, event: event, senderName: sender, names: names,
        settings: settings, store: store, decrypt: LoafPush.decrypt,
        rules: rules, power: power, notifies: LoafPush.notifies, now: Date())
      Self.log.info("\(shown.outcome, privacy: .public)")
      if shown.drop { return self.suppress() }
      out.title = shown.title
      out.body = shown.body
      self.finish(out)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let best { finish(best) }
  }

  private func finish(_ content: UNNotificationContent) {
    deliver?(content)
    deliver = nil
  }

  /// Show nothing: the rules silenced this message. An empty content is how
  /// a filtering extension drops a push.
  private func suppress() { finish(UNNotificationContent()) }

  /// One authenticated GET against the homeserver, or nil.
  private static func get(_ s: Session, _ path: String) async -> [String: Any]? {
    var req = URLRequest(url: s.homeserver.appendingPathComponent(path))
    req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 10
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
      (resp as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func usable(_ s: Session?) -> Session? {
    guard let s, (s.expiresAt ?? .distantFuture) > Date() else { return nil }
    return s
  }

  private static func escaped(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  /// The event and its sender's display name; nil, nil when the token is
  /// missing or expired or either request fails.
  private static func fetch(_ s: Session?, roomId: String, eventId: String) async -> (
    [String: Any]?, String?
  ) {
    guard let s = usable(s) else { return (nil, nil) }
    let room = escaped(roomId)
    guard let event = await get(s, "_matrix/client/v3/rooms/\(room)/event/\(escaped(eventId))")
    else { return (nil, nil) }
    let sender = (event["sender"] as? String) ?? ""
    let member = await get(
      s, "_matrix/client/v3/rooms/\(room)/state/m.room.member/\(escaped(sender))")
    return (event, (member?["displayname"] as? String) ?? sender)
  }

  /// One room state event, for the power levels the rules judge against.
  private static func state(_ s: Session?, roomId: String, type: String) async -> [String: Any]? {
    guard let s = usable(s) else { return nil }
    return await get(s, "_matrix/client/v3/rooms/\(escaped(roomId))/state/\(type)")
  }

  /// The account's rules, for a cache that is missing or over an hour old.
  /// `/pushrules/` answers `{"global": {...}}` and knows nothing about your
  /// display name, so the ruleset is unwrapped and the cached name carried
  /// over: without it `contains_display_name` would stop matching on exactly
  /// the pushes that took this path.
  private static func rules(_ s: Session?, keeping cached: Rules?) async -> Rules? {
    guard let s = usable(s),
      let body = await get(s, "_matrix/client/v3/pushrules/"),
      let global = body["global"]
    else { return nil }
    var file: [String: Any] = ["user_id": s.userId, "rules": global]
    if let cached, let old = try? JSONSerialization.jsonObject(with: cached.json),
      let name = (old as? [String: Any])?["display_name"]
    {
      file["display_name"] = name
    }
    guard let wrapped = try? JSONSerialization.data(withJSONObject: file) else { return nil }
    return Rules(json: wrapped, writtenAt: nil)
  }
}

/// The three C functions of loaf_push, found in the app's Frameworks at run
/// time: there is no header, by choice (Rust, Dart and Swift only).
enum LoafPush {
  private typealias DecryptFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
  ) -> UnsafeMutablePointer<CChar>?
  private typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private typealias NotifiesFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int64, UnsafePointer<CChar>?
  ) -> Int32

  private static let fns: (DecryptFn, FreeFn, NotifiesFn)? = {
    // <appex>/../../Frameworks: the app's, as Task 3 recorded the name.
    let lib = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Frameworks/loaf_push.framework/loaf_push").path
    guard let h = dlopen(lib, RTLD_NOW), let d = dlsym(h, "loaf_push_decrypt"),
      let f = dlsym(h, "loaf_push_free"), let n = dlsym(h, "loaf_push_notifies")
    else { return nil }
    return (
      unsafeBitCast(d, to: DecryptFn.self), unsafeBitCast(f, to: FreeFn.self),
      unsafeBitCast(n, to: NotifiesFn.self)
    )
  }()

  static func decrypt(_ pickle: String, _ userId: String, _ ciphertext: String) -> String? {
    guard let fns else { return nil }
    guard let out = fns.0(pickle, userId, ciphertext) else { return nil }
    defer { fns.1(out) }
    return String(cString: out)
  }

  /// nil when the library is missing or the verdict is undecidable: the
  /// caller shows the message.
  static func notifies(
    _ rules: Data, _ event: [String: Any], _ members: Int?, _ power: [String: Any]?
  ) -> Bool? {
    guard let fns, let rulesText = String(data: rules, encoding: .utf8),
      let eventData = try? JSONSerialization.data(withJSONObject: event),
      let eventText = String(data: eventData, encoding: .utf8)
    else { return nil }
    let powerText =
      power
      .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
      .flatMap { String(data: $0, encoding: .utf8) }
    switch fns.2(rulesText, eventText, Int64(members ?? -1), powerText) {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }
}
