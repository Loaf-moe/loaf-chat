import XCTest

@testable import LoafMediaCore

final class RangeLedgerTests: XCTestCase {
  private func arrived(
    _ received: Int64, total: Int64? = 10_000_000, complete: Bool = false,
    failed: Bool = false
  ) -> StreamProgress {
    StreamProgress(received: received, total: total, complete: complete, failed: failed)
  }

  func testRespondsWithWhatHasArrived() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: 1000, currentOffset: 0, progress: arrived(400)),
      .respond(offset: 0, length: 400))
  }

  func testWaitsPastTheDownload() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: 1000, currentOffset: 400, progress: arrived(400)),
      .wait)
  }

  func testFinishesWhenTheRangeIsCovered() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: 1000, currentOffset: 1000, progress: arrived(4000)),
      .finish)
  }

  func testToEndFinishesOnlyWhenComplete() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: nil, currentOffset: 500,
        progress: arrived(500, total: 500)),
      .wait)
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: nil, currentOffset: 500,
        progress: arrived(500, total: 500, complete: true)),
      .finish)
  }

  func testChunksBigResponses() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: nil, currentOffset: 0,
        progress: arrived(10_000_000)),
      .respond(offset: 0, length: 262_144))
  }

  func testAFailedStreamFailsPendingRequests() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: 1000, currentOffset: 400,
        progress: arrived(400, failed: true)),
      .fail)
  }

  func testSeekAheadWaits() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 5_000_000, requestedLength: 1000, currentOffset: 5_000_000,
        progress: arrived(1_000_000)),
      .wait)
  }

  /// A request that starts mid-range only gets bytes from its own offset.
  func testRespondsFromTheCurrentOffset() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 100, requestedLength: 1000, currentOffset: 300, progress: arrived(800)),
      .respond(offset: 300, length: 500))
  }

  /// Nothing more will come, so a range past the end ends short.
  func testARangePastACompleteFileFinishes() {
    XCTAssertEqual(
      nextStep(
        requestedOffset: 0, requestedLength: 1000, currentOffset: 500,
        progress: arrived(500, total: 500, complete: true)),
      .finish)
  }
}
