import XCTest
@testable import ClaudeUsageCore

final class FormattingTests: XCTestCase {

    func testCountdownVariants() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(82 * 60), now: now), "1h 22m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(6 * 86400 + 8 * 3600), now: now), "6d 8h")
    }

    func testPercentFormatting() {
        XCTAssertEqual(Formatting.percent(0.30), "30%")
        XCTAssertEqual(Formatting.percent(0.43), "43%")
        XCTAssertEqual(Formatting.percent(0), "0%")
        XCTAssertEqual(Formatting.percent(1), "100%")
        XCTAssertEqual(Formatting.percent(1.5), "100%")
    }
}
