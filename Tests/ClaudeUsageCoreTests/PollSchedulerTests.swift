import XCTest
@testable import ClaudeUsageCore

final class PollSchedulerTests: XCTestCase {

    func testSuccessAlwaysReturnsSteadyInterval() {
        var scheduler = PollScheduler()
        XCTAssertEqual(scheduler.nextDelayAfterSuccess(), 60)
        XCTAssertEqual(scheduler.nextDelayAfterSuccess(), 60)
    }

    func testFailureBacksOffAndCaps() {
        var scheduler = PollScheduler()
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 60)
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 120)
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 240)
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 300) // capped
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 300)
    }

    func testSuccessResetsBackoff() {
        var scheduler = PollScheduler()
        _ = scheduler.nextDelayAfterFailure() // 60 -> backoff now 120
        _ = scheduler.nextDelayAfterFailure() // 120 -> backoff now 240
        XCTAssertEqual(scheduler.nextDelayAfterSuccess(), 60)
        XCTAssertEqual(scheduler.nextDelayAfterFailure(), 60) // back to initial
    }

    func testRateLimitedUsesRetryAfterWhenLarger() {
        var scheduler = PollScheduler()
        XCTAssertEqual(scheduler.nextDelayAfterRateLimited(retryAfter: 200), 200)
    }

    func testRateLimitedUsesBackoffWhenRetryAfterSmallerOrNil() {
        var scheduler = PollScheduler()
        XCTAssertEqual(scheduler.nextDelayAfterRateLimited(retryAfter: nil), 60)
        XCTAssertEqual(scheduler.nextDelayAfterRateLimited(retryAfter: 10), 120)
    }
}
