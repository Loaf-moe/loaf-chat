import XCTest

@testable import LoafMediaCore

final class AudioClaimTests: XCTestCase {
  func testFirstUnmutedPlayClaims() {
    var claim = AudioClaim()
    XCTAssertEqual(claim.update(view: 1, playing: true, muted: false), .claim)
    XCTAssertTrue(claim.isClaimed)
  }

  func testASecondVideoPlayingChangesNothing() {
    var claim = AudioClaim()
    _ = claim.update(view: 1, playing: true, muted: false)
    XCTAssertNil(claim.update(view: 2, playing: true, muted: false))
  }

  func testOneOfTwoStoppingChangesNothing() {
    var claim = AudioClaim()
    _ = claim.update(view: 1, playing: true, muted: false)
    _ = claim.update(view: 2, playing: true, muted: false)
    XCTAssertNil(claim.update(view: 1, playing: false, muted: false))
    XCTAssertTrue(claim.isClaimed)
  }

  func testTheLastStoppingReleases() {
    var claim = AudioClaim()
    _ = claim.update(view: 1, playing: true, muted: false)
    _ = claim.update(view: 2, playing: true, muted: false)
    _ = claim.update(view: 1, playing: false, muted: false)
    XCTAssertEqual(claim.update(view: 2, playing: false, muted: false), .release)
    XCTAssertFalse(claim.isClaimed)
  }

  func testMutingTheOnlyPlayingVideoReleasesAndUnmutingClaims() {
    var claim = AudioClaim()
    _ = claim.update(view: 1, playing: true, muted: false)
    XCTAssertEqual(claim.update(view: 1, playing: true, muted: true), .release)
    XCTAssertEqual(claim.update(view: 1, playing: true, muted: false), .claim)
  }

  func testTeardownOfAPlayingVideoReleases() {
    var claim = AudioClaim()
    _ = claim.update(view: 1, playing: true, muted: false)
    XCTAssertEqual(claim.remove(view: 1), .release)
  }

  func testAMutedVideoStartingChangesNothing() {
    var claim = AudioClaim()
    XCTAssertNil(claim.update(view: 1, playing: true, muted: true))
    XCTAssertFalse(claim.isClaimed)
  }

  func testRepeatsAndUnknownRemovalsChangeNothing() {
    var claim = AudioClaim()
    XCTAssertNil(claim.update(view: 1, playing: false, muted: false))
    XCTAssertNil(claim.remove(view: 9))
    _ = claim.update(view: 1, playing: true, muted: false)
    XCTAssertNil(claim.update(view: 1, playing: true, muted: false))
  }
}
