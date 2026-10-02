import XCTest

@testable import LoafMediaCore

final class PictureInPictureTests: XCTestCase {
  func testStartsThenStops() {
    var pip = PictureInPicture()
    XCTAssertNil(pip.handle(.willStart))
    XCTAssertTrue(pip.keepsPlayer, "kept while it starts, so the row can go")
    XCTAssertEqual(pip.handle(.didStart), true)
    XCTAssertTrue(pip.keepsPlayer)
    XCTAssertEqual(pip.handle(.didStop), false)
    XCTAssertFalse(pip.keepsPlayer)
  }

  func testAFailedStartLetsGo() {
    var pip = PictureInPicture()
    _ = pip.handle(.willStart)
    XCTAssertEqual(pip.handle(.failedToStart), false)
    XCTAssertFalse(pip.keepsPlayer)
    XCTAssertEqual(pip.state, .idle)
  }

  func testAStopOrFailureWithNothingActiveIsANoOp() {
    var pip = PictureInPicture()
    XCTAssertNil(pip.handle(.didStop))
    XCTAssertNil(pip.handle(.failedToStart))
    XCTAssertEqual(pip.state, .idle)
    XCTAssertFalse(pip.keepsPlayer)
  }

  func testRepeatsAreNoOps() {
    var pip = PictureInPicture()
    _ = pip.handle(.willStart)
    _ = pip.handle(.didStart)
    XCTAssertNil(pip.handle(.willStart))
    XCTAssertNil(pip.handle(.didStart))
    XCTAssertEqual(pip.state, .active)
  }

  func testADidStartWithoutWillStartStillCounts() {
    var pip = PictureInPicture()
    XCTAssertEqual(pip.handle(.didStart), true)
    XCTAssertTrue(pip.keepsPlayer)
  }
}
