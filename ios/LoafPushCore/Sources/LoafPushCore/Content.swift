import Foundation

/// Every string the extension can put on screen, in one place, so they stay
/// the same words the app's own notices use.
public enum Copy {
  public static let newMessage = "new message"
  public static let picture = "sent a picture"
  public static let file = "sent a file"
  public static let encrypted = "encrypted message"
  /// Platforms truncate long text anyway, and the app cuts at the same
  /// place — see `noticeTextLimit` in lib/ui/model/notice.dart.
  public static let textLimit = 400
  public static let ellipsis = "…"
}

/// The verdict, nil when it cannot be reached; the caller then shows the
/// message. Task 3a's `loaf_push_notifies` behind a seam, as `Decrypt` is.
public typealias Notifies = (
  _ rules: Data, _ event: [String: Any], _ members: Int?, _ power: [String: Any]?
) -> Bool?

public typealias Decrypt = (
  _ pickle: String, _ userId: String, _ ciphertext: String
) -> String?

public struct Shown: Equatable {
  public let title: String
  public let body: String
  public let outcome: String
  public let drop: Bool

  public init(title: String, body: String, outcome: String, drop: Bool) {
    self.title = title
    self.body = body
    self.outcome = outcome
    self.drop = drop
  }
}

private let dropped = Shown(title: "", body: "", outcome: "dropped", drop: true)

/// What to put on screen for one push.
///
/// The order is the point. Reading the message comes before judging it, and
/// every way of failing to read it ends in showing the message: a push we
/// could not fetch, could not decrypt, or have no rules for is announced,
/// because the alternative is silently losing a mention. Only a message we
/// read and then judged is ever dropped.
public func content(
  roomId: String,
  event: [String: Any]?,
  senderName: String?,
  names: [String: RoomName],
  settings: DeviceSettings,
  store: Store?,
  decrypt: Decrypt,
  rules: Rules?,
  power: [String: Any]?,
  notifies: Notifies,
  now: Date
) -> Shown {
  let name = names[roomId]
  func shown(_ body: String, _ outcome: String) -> Shown {
    Shown(
      title: title(place: name?.place, sender: senderName),
      body: body,
      outcome: outcome,
      drop: false
    )
  }

  // The pusher should already be gone when notifications are off; this is
  // for a push that was in flight when it went.
  guard settings.notifications else {
    return Shown(title: "", body: "", outcome: "off", drop: true)
  }

  guard let event else { return shown(Copy.newMessage, "fetch-failed") }

  var read = event
  var wasEncrypted = false
  if event["type"] as? String == "m.room.encrypted" {
    guard
      let plaintext = open(event: event, roomId: roomId, store: store, decrypt: decrypt)
    else {
      return shown(Copy.encrypted, "no-key")
    }
    read = plaintext
    wasEncrypted = true
  }

  let text = body(of: read, showText: settings.showText)

  guard let rules else { return shown(text, "no-rules") }
  guard let verdict = notifies(rules.json, read, name?.members, power) else {
    return shown(text, "undecided")
  }
  guard verdict else { return dropped }
  return shown(text, wasEncrypted ? "decrypted" : "shown")
}

/// The plaintext, only when every link holds: a key we have, filed under
/// this room, that opens, and whose plaintext claims this room. A key from
/// elsewhere, or a plaintext naming another room, is a message re-keyed
/// from somewhere we cannot vouch for.
private func open(
  event: [String: Any],
  roomId: String,
  store: Store?,
  decrypt: Decrypt
) -> [String: Any]? {
  guard let content = event["content"] as? [String: Any],
    let sessionId = content["session_id"] as? String,
    let ciphertext = content["ciphertext"] as? String,
    let store,
    let key = store.roomKey(sessionId: sessionId),
    key.roomId == roomId,
    let userId = store.userId(),
    let text = decrypt(key.pickle, userId, ciphertext),
    let plaintext = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
      as? [String: Any],
    plaintext["room_id"] as? String == roomId
  else { return nil }
  return plaintext
}

private func body(of event: [String: Any], showText: Bool) -> String {
  guard showText else { return Copy.newMessage }
  let content = event["content"] as? [String: Any] ?? [:]
  switch content["msgtype"] as? String {
  case "m.image":
    return Copy.picture
  case "m.file", "m.video", "m.audio":
    return Copy.file
  default:
    let text = (content["body"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return Copy.newMessage }
    // By Character, so an emoji or a combining mark is never split.
    if text.count <= Copy.textLimit { return text }
    return String(text.prefix(Copy.textLimit)) + Copy.ellipsis
  }
}

/// `mochi`, `#general · Pack`, or `mochi in #general · Pack` — the same
/// shape as `Notice.title` in the app.
private func title(place: String?, sender: String?) -> String {
  let sender = (sender ?? "").trimmingCharacters(in: .whitespaces)
  guard let place, !place.isEmpty else { return sender }
  return sender.isEmpty ? place : "\(sender) in \(place)"
}
