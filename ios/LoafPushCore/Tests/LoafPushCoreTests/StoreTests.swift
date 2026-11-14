import XCTest

@testable import LoafPushCore

/// The extension reads loaf.sqlite with no SDK. These hold it to the shape
/// the Dart pin recorded, so a drift fails on a Mac rather than on a phone.
final class StoreTests: XCTestCase {
  private func openedStore() throws -> (Store, [String: Any]) {
    let fixture = try sdkFixture()
    let path = try tempDirectory(self).appendingPathComponent("loaf.sqlite").path
    try writeStore(at: path, fixture: fixture)
    return (try XCTUnwrap(Store(path: path)), fixture)
  }

  func testSessionReadsWhoYouAreAndWhereFrom() throws {
    let (store, fixture) = try openedStore()
    let client = try XCTUnwrap(fixture["client"] as? [String: Any])
    let session = try XCTUnwrap(store.session())
    XCTAssertEqual(session.userId, client["user_id"] as? String)
    XCTAssertEqual(session.token, client["token"] as? String)
    XCTAssertEqual(
      session.homeserver.absoluteString,
      client["homeserver_url"] as? String
    )
    // The fixture records no expiry, and a token with none never goes stale.
    XCTAssertNil(session.expiresAt)
  }

  func testRoomKeyReturnsTheRoomAndThePickle() throws {
    let (store, fixture) = try openedStore()
    let row = try XCTUnwrap(fixture["session_row"] as? String)
    let parsed = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any]
    )
    let sessionId = try XCTUnwrap(parsed["session_id"] as? String)
    let key = try XCTUnwrap(store.roomKey(sessionId: sessionId))
    XCTAssertEqual(key.roomId, fixture["room_id"] as? String)
    XCTAssertEqual(key.pickle, parsed["pickle"] as? String)
  }

  func testAnUnknownSessionHasNoKey() throws {
    let (store, _) = try openedStore()
    XCTAssertNil(store.roomKey(sessionId: "never-seen"))
  }

  func testAMissingDatabaseOpensNothing() throws {
    let path = try tempDirectory(self).appendingPathComponent("absent.sqlite").path
    XCTAssertNil(Store(path: path))
  }
}
