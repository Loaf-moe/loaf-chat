import Foundation
import SQLite3

public struct Session {
  public let homeserver: URL
  public let token: String
  public let expiresAt: Date?
  public let userId: String

  public init(homeserver: URL, token: String, expiresAt: Date?, userId: String) {
    self.homeserver = homeserver
    self.token = token
    self.expiresAt = expiresAt
    self.userId = userId
  }
}

public struct RoomKey {
  public let roomId: String
  public let pickle: String

  public init(roomId: String, pickle: String) {
    self.roomId = roomId
    self.pickle = pickle
  }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only over the app's `loaf.sqlite`. The extension has no SDK, so it
/// reads the two boxes `test/push/storage_pin_test.dart` pins: `box_client`,
/// whose values are the raw strings the SDK stores — not JSON — and
/// `box_inbound_group_session`, whose values are a JSON object per session.
public final class Store {
  private let db: OpaquePointer

  public init?(path: String) {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let opened = handle
    else {
      if let handle { sqlite3_close(handle) }
      return nil
    }
    // The app owns this file. Nothing here may write to it — not a journal
    // recovery, not a checkpoint — or the two will fight over a lock in a
    // shared container, which is how iOS comes to kill us.
    sqlite3_exec(opened, "PRAGMA query_only=1", nil, nil, nil)
    db = opened
  }

  deinit { sqlite3_close(db) }

  private func value(table: String, key: String) -> String? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT v FROM \(table) WHERE k = ?", -1, &statement, nil)
        == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, transient)
    guard sqlite3_step(statement) == SQLITE_ROW,
      let text = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: text)
  }

  /// Just who you are. Decryption needs the pickle key, which is derived
  /// from the user id, and nothing else about the session — a store whose
  /// homeserver or token is unreadable can still open a message.
  public func userId() -> String? {
    value(table: "box_client", key: "user_id")
  }

  public func session() -> Session? {
    guard
      let address = value(table: "box_client", key: "homeserver_url"),
      let homeserver = URL(string: address),
      let token = value(table: "box_client", key: "token"),
      let userId = value(table: "box_client", key: "user_id")
    else { return nil }
    return Session(
      homeserver: homeserver,
      token: token,
      expiresAt: expiry(),
      userId: userId
    )
  }

  /// Milliseconds since the epoch, as the SDK writes them. No row, an
  /// unparseable one, or zero all mean a token that does not expire.
  private func expiry() -> Date? {
    guard let raw = value(table: "box_client", key: "token_expires_at"),
      let milliseconds = Double(raw.trimmingCharacters(in: .whitespaces)),
      milliseconds > 0
    else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  public func roomKey(sessionId: String) -> RoomKey? {
    guard let row = value(table: "box_inbound_group_session", key: sessionId),
      let object = (try? JSONSerialization.jsonObject(with: Data(row.utf8)))
        as? [String: Any],
      let roomId = object["room_id"] as? String,
      let pickle = object["pickle"] as? String
    else { return nil }
    return RoomKey(roomId: roomId, pickle: pickle)
  }
}
