import XCTest

@testable import LoafPushCore

/// rules.json is the one file the extension must not guess at: an empty
/// ruleset silences everything, so "no file" and "a file" are different
/// answers and only the second is trusted.
final class RulesTests: XCTestCase {
  private func write(_ document: [String: Any]) throws -> URL {
    let url = try tempDirectory(self).appendingPathComponent("rules.json")
    try JSONSerialization.data(withJSONObject: document).write(to: url)
    return url
  }

  func testAMissingFileIsNoRules() throws {
    let url = try tempDirectory(self).appendingPathComponent("rules.json")
    XCTAssertNil(loadRules(url))
  }

  func testRubbishIsNoRules() throws {
    let url = try tempDirectory(self).appendingPathComponent("rules.json")
    try Data("not json".utf8).write(to: url)
    XCTAssertNil(loadRules(url))
  }

  func testADocumentWithoutRulesIsNoRules() throws {
    let url = try write(["user_id": "@mochi:loaf.moe", "written_at": 0])
    XCTAssertNil(loadRules(url))
  }

  func testTheWholeDocumentIsKeptForTheEvaluator() throws {
    let written = Date(timeIntervalSince1970: 1_700_000_000)
    let url = try write([
      "user_id": "@mochi:loaf.moe",
      "display_name": "mochi",
      "written_at": Int(written.timeIntervalSince1970 * 1000),
      "rules": ["override": [], "underride": []],
    ])
    let rules = try XCTUnwrap(loadRules(url))
    XCTAssertEqual(rules.writtenAt, written)
    // The evaluator is handed the document, user id and name included.
    let parsed = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: rules.json) as? [String: Any]
    )
    XCTAssertEqual(parsed["user_id"] as? String, "@mochi:loaf.moe")
    XCTAssertEqual(parsed["display_name"] as? String, "mochi")
    XCTAssertNotNil(parsed["rules"])
  }

  func testNoRulesIsStale() {
    XCTAssertTrue(isStale(nil, now: Date()))
  }

  func testAnHourOldIsNotYetStale() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let url = try write([
      "written_at": Int((now.timeIntervalSince1970 - 3000) * 1000),
      "rules": [:],
    ])
    XCTAssertFalse(isStale(loadRules(url), now: now))
  }

  func testOlderThanAnHourIsStale() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let url = try write([
      "written_at": Int((now.timeIntervalSince1970 - 3601) * 1000),
      "rules": [:],
    ])
    XCTAssertTrue(isStale(loadRules(url), now: now))
  }

  func testRulesWithNoTimestampAreStale() throws {
    let url = try write(["rules": [:]])
    XCTAssertTrue(isStale(loadRules(url), now: Date()))
  }
}
