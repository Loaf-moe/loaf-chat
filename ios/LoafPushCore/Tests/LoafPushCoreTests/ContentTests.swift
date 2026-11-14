import XCTest

@testable import LoafPushCore

/// What the extension puts on screen, and what it refuses to put there.
/// The ordering matters more than any single string: every path that could
/// not read the message shows it, and only a message we read and judged is
/// ever dropped.
final class ContentTests: XCTestCase {
  private let dm = "!d"
  private let channel = "!g"
  private let session = "sess-1"

  private var names: [String: RoomName] {
    [
      dm: RoomName(place: nil, dm: true, members: 2),
      channel: RoomName(place: "#general · Pack", dm: false, members: 12),
    ]
  }

  /// Answers every call with this plaintext, whatever it is handed.
  private func decrypting(_ plaintext: [String: Any]) -> Decrypt {
    { _, _, _ in jsonText(plaintext) }
  }

  private var refusing: Decrypt { { _, _, _ in nil } }

  private final class Verdict {
    private let answer: Bool?
    private(set) var calls: [(rules: Data, event: [String: Any], members: Int?)] = []
    init(_ answer: Bool?) { self.answer = answer }
    var notifies: Notifies {
      { rules, event, members, _ in
        self.calls.append((rules, event, members))
        return self.answer
      }
    }
  }

  private func someRules() -> Rules {
    Rules(json: Data(jsonText(["rules": [:]]).utf8), writtenAt: Date())
  }

  private func encrypted(room: String, session: String) -> [String: Any] {
    [
      "type": "m.room.encrypted",
      "room_id": room,
      "content": [
        "algorithm": "m.megolm.v1.aes-sha2",
        "ciphertext": "AwgAEnC",
        "session_id": session,
      ],
    ]
  }

  private func message(room: String, msgtype: String, body: String) -> [String: Any] {
    [
      "type": "m.room.message",
      "room_id": room,
      "content": ["msgtype": msgtype, "body": body],
    ]
  }

  private func shown(
    roomId: String? = nil,
    event: [String: Any]?,
    senderName: String? = "mochi",
    settings: DeviceSettings = DeviceSettings(),
    store: Store? = nil,
    decrypt: Decrypt? = nil,
    rules: Rules? = nil,
    notifies: Notifies? = nil
  ) -> Shown {
    content(
      roomId: roomId ?? dm,
      event: event,
      senderName: senderName,
      names: names,
      settings: settings,
      store: store,
      decrypt: decrypt ?? refusing,
      rules: rules,
      power: nil,
      notifies: notifies ?? { _, _, _, _ in true },
      now: Date()
    )
  }

  // MARK: reading the message

  func testAnEncryptedMessageWithItsKeyIsRead() throws {
    let store = try storeWith(self, sessions: [(session, dm, "pickle")])
    let result = shown(
      event: encrypted(room: dm, session: session),
      store: store,
      decrypt: decrypting(message(room: dm, msgtype: "m.text", body: "hi")),
      rules: someRules()
    )
    XCTAssertEqual(result, Shown(title: "mochi", body: "hi", outcome: "decrypted", drop: false))
  }

  func testWithoutTheKeyItSaysSoRatherThanNothing() {
    let result = shown(event: encrypted(room: dm, session: session))
    XCTAssertEqual(
      result,
      Shown(title: "mochi", body: "encrypted message", outcome: "no-key", drop: false)
    )
  }

  func testAKeyForAnotherRoomIsNotTrusted() throws {
    // The key opens, but the plaintext claims a different room: a message
    // re-keyed from elsewhere must never be shown as this room's.
    let store = try storeWith(self, sessions: [(session, dm, "pickle")])
    let result = shown(
      event: encrypted(room: dm, session: session),
      store: store,
      decrypt: decrypting(message(room: "!other", msgtype: "m.text", body: "hi"))
    )
    XCTAssertEqual(result.body, "encrypted message")
    XCTAssertEqual(result.outcome, "no-key")
  }

  func testAKeyFiledUnderAnotherRoomIsNotUsed() throws {
    let store = try storeWith(self, sessions: [(session, "!other", "pickle")])
    let result = shown(
      event: encrypted(room: dm, session: session),
      store: store,
      decrypt: decrypting(message(room: dm, msgtype: "m.text", body: "hi"))
    )
    XCTAssertEqual(result.outcome, "no-key")
  }

  func testAMessageWeCouldNotFetchIsStillAnnounced() {
    let result = shown(roomId: channel, event: nil, senderName: nil)
    XCTAssertEqual(
      result,
      Shown(
        title: "#general · Pack",
        body: "new message",
        outcome: "fetch-failed",
        drop: false
      )
    )
  }

  // MARK: the text

  func testShowTextOffSaysOnlyThatSomethingArrived() {
    var settings = DeviceSettings()
    settings.showText = false
    let result = shown(
      event: message(room: dm, msgtype: "m.text", body: "hi"),
      settings: settings
    )
    XCTAssertEqual(result.body, "new message")
  }

  func testAPicture() {
    let result = shown(event: message(room: dm, msgtype: "m.image", body: "cat.png"))
    XCTAssertEqual(result.body, "sent a picture")
  }

  func testFilesVideoAndAudioAreAllFiles() {
    for msgtype in ["m.file", "m.video", "m.audio"] {
      let result = shown(event: message(room: dm, msgtype: msgtype, body: "x"))
      XCTAssertEqual(result.body, "sent a file", "for \(msgtype)")
    }
  }

  func testLongTextIsCutToFourHundredCharacters() {
    let long = String(repeating: "a", count: 401)
    let result = shown(event: message(room: dm, msgtype: "m.text", body: long))
    XCTAssertEqual(result.body, String(repeating: "a", count: 400) + "…")
  }

  func testAnEmptyBodyFallsBackRatherThanShowingNothing() {
    let result = shown(event: message(room: dm, msgtype: "m.text", body: "   "))
    XCTAssertEqual(result.body, "new message")
  }

  func testASenderInAChannelNamesBoth() {
    let result = shown(
      roomId: channel,
      event: message(room: channel, msgtype: "m.text", body: "hi")
    )
    XCTAssertEqual(result.title, "mochi in #general · Pack")
  }

  // MARK: the verdict

  func testTheRulesCanDropIt() throws {
    let store = try storeWith(self, sessions: [(session, dm, "pickle")])
    let verdict = Verdict(false)
    let plaintext = message(room: dm, msgtype: "m.text", body: "hi")
    let result = shown(
      event: encrypted(room: dm, session: session),
      store: store,
      decrypt: decrypting(plaintext),
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertEqual(result, Shown(title: "", body: "", outcome: "dropped", drop: true))
    // It judges what was said, not the envelope it came in.
    XCTAssertEqual(verdict.calls.count, 1)
    XCTAssertEqual(verdict.calls[0].event["type"] as? String, "m.room.message")
    XCTAssertEqual(verdict.calls[0].members, 2)
  }

  func testTheRulesCanLetItThrough() {
    let verdict = Verdict(true)
    let result = shown(
      event: message(room: dm, msgtype: "m.text", body: "hi"),
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertFalse(result.drop)
    XCTAssertEqual(result.body, "hi")
    XCTAssertEqual(verdict.calls.count, 1)
  }

  func testNoRulesFileFailsOpenWithoutAsking() {
    let verdict = Verdict(false)
    let result = shown(
      event: message(room: dm, msgtype: "m.text", body: "hi"),
      rules: nil,
      notifies: verdict.notifies
    )
    XCTAssertFalse(result.drop)
    XCTAssertEqual(result.outcome, "no-rules")
    XCTAssertTrue(verdict.calls.isEmpty)
  }

  func testAnUndecidedVerdictFailsOpen() {
    let verdict = Verdict(nil)
    let result = shown(
      event: message(room: dm, msgtype: "m.text", body: "hi"),
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertFalse(result.drop)
    XCTAssertEqual(result.outcome, "undecided")
  }

  func testAMessageWeCouldNotReadIsNeverJudged() {
    let verdict = Verdict(false)
    let result = shown(
      event: encrypted(room: dm, session: session),
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertFalse(result.drop)
    XCTAssertEqual(result.outcome, "no-key")
    XCTAssertTrue(verdict.calls.isEmpty)
  }

  func testAMessageWeCouldNotFetchIsNeverJudged() {
    let verdict = Verdict(false)
    let result = shown(
      roomId: channel,
      event: nil,
      senderName: nil,
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertFalse(result.drop)
    XCTAssertEqual(result.outcome, "fetch-failed")
    XCTAssertTrue(verdict.calls.isEmpty)
  }

  func testNotificationsOffDropsItBeforeAnythingElse() {
    var settings = DeviceSettings()
    settings.notifications = false
    let verdict = Verdict(true)
    let result = shown(
      event: message(room: dm, msgtype: "m.text", body: "hi"),
      settings: settings,
      rules: someRules(),
      notifies: verdict.notifies
    )
    XCTAssertEqual(result, Shown(title: "", body: "", outcome: "off", drop: true))
    XCTAssertTrue(verdict.calls.isEmpty)
  }
}
