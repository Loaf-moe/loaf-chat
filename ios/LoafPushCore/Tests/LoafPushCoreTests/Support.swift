import Foundation
import SQLite3
import XCTest

@testable import LoafPushCore

/// The repository root, from this file's own path: the fixture is the Dart
/// side's recording of what the SDK writes, and the Swift reader must be
/// held to the same shape rather than to a copy that can drift.
func repoRoot() -> URL {
  var url = URL(fileURLWithPath: #filePath)
  for _ in 0 ..< 5 { url = url.deletingLastPathComponent() }
  return url
}

func sdkFixture() throws -> [String: Any] {
  let url = repoRoot().appendingPathComponent(
    "packages/loaf_push/rust/tests/fixtures/sdk.json"
  )
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
  return try XCTUnwrap(object as? [String: Any])
}

let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func tempDirectory(_ test: XCTestCase) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("loafpush-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
  return url
}

/// A loaf.sqlite holding exactly what the fixture recorded. box_client
/// values go in as the raw strings the SDK stores — not JSON — which is
/// what test/push/storage_pin_test.dart pins.
func writeStore(at path: String, fixture: [String: Any]) throws {
  var db: OpaquePointer?
  XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
  defer { sqlite3_close(db) }
  for table in ["box_client", "box_inbound_group_session"] {
    XCTAssertEqual(
      sqlite3_exec(db, "CREATE TABLE \(table) (k TEXT PRIMARY KEY, v TEXT)", nil, nil, nil),
      SQLITE_OK
    )
  }
  func put(_ table: String, _ key: String, _ value: String) {
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "INSERT INTO \(table) (k, v) VALUES (?, ?)", -1, &statement, nil),
      SQLITE_OK
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, transient)
    sqlite3_bind_text(statement, 2, value, -1, transient)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }
  let client = fixture["client"] as? [String: Any] ?? [:]
  for (key, value) in client {
    if let text = value as? String { put("box_client", key, text) }
  }
  let row = fixture["session_row"] as? String ?? ""
  let parsed = (try? JSONSerialization.jsonObject(with: Data(row.utf8))) as? [String: Any]
  if let sessionId = parsed?["session_id"] as? String {
    put("box_inbound_group_session", sessionId, row)
  }
}

/// A store holding just these megolm sessions, for the cases where what
/// matters is which room a key belongs to.
func storeWith(
  _ test: XCTestCase,
  sessions: [(id: String, roomId: String, pickle: String)]
) throws -> Store {
  let path = try tempDirectory(test).appendingPathComponent("loaf.sqlite").path
  var db: OpaquePointer?
  XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
  for table in ["box_client", "box_inbound_group_session"] {
    XCTAssertEqual(
      sqlite3_exec(db, "CREATE TABLE \(table) (k TEXT PRIMARY KEY, v TEXT)", nil, nil, nil),
      SQLITE_OK
    )
  }
  var clientStatement: OpaquePointer?
  XCTAssertEqual(
    sqlite3_prepare_v2(
      db, "INSERT INTO box_client (k, v) VALUES (?, ?)", -1, &clientStatement, nil
    ),
    SQLITE_OK
  )
  sqlite3_bind_text(clientStatement, 1, "user_id", -1, transient)
  sqlite3_bind_text(clientStatement, 2, "@mochi:loaf.moe", -1, transient)
  XCTAssertEqual(sqlite3_step(clientStatement), SQLITE_DONE)
  sqlite3_finalize(clientStatement)
  for session in sessions {
    let row = try JSONSerialization.data(withJSONObject: [
      "room_id": session.roomId,
      "session_id": session.id,
      "pickle": session.pickle,
    ])
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        db,
        "INSERT INTO box_inbound_group_session (k, v) VALUES (?, ?)",
        -1, &statement, nil
      ),
      SQLITE_OK
    )
    sqlite3_bind_text(statement, 1, session.id, -1, transient)
    sqlite3_bind_text(statement, 2, String(decoding: row, as: UTF8.self), -1, transient)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
  }
  sqlite3_close(db)
  return try XCTUnwrap(Store(path: path))
}

func jsonText(_ object: [String: Any]) -> String {
  let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  return String(decoding: data, as: UTF8.self)
}
