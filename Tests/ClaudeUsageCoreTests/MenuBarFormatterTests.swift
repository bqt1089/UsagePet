import XCTest
@testable import ClaudeUsageCore

final class MenuBarFormatterTests: XCTestCase {

    func testNilShowsPlaceholder() {
        XCTAssertEqual(MenuBarFormatter.label(session: nil, weekly: nil, style: .session), "–")
        XCTAssertEqual(MenuBarFormatter.label(session: nil, weekly: nil, style: .sessionAndWeekly), "– · –")
    }

    func testRoundingAndBoth() {
        XCTAssertEqual(MenuBarFormatter.label(session: 41.6, weekly: 57, style: .session), "42%")
        XCTAssertEqual(MenuBarFormatter.label(session: 41.6, weekly: 57, style: .sessionAndWeekly), "42% · 57%")
        XCTAssertEqual(MenuBarFormatter.label(session: 10, weekly: nil, style: .sessionAndWeekly), "10% · –")
    }

    func testClampsAndIconOnly() {
        XCTAssertEqual(MenuBarFormatter.label(session: 130, weekly: -5, style: .sessionAndWeekly), "100% · 0%")
        XCTAssertEqual(MenuBarFormatter.label(session: 50, weekly: 50, style: .iconOnly), "")
    }

    func testWarningThresholds() {
        XCTAssertFalse(MenuBarFormatter.showsWarning(session: 89.9, weekly: 94.9))
        XCTAssertTrue(MenuBarFormatter.showsWarning(session: 90, weekly: nil))
        XCTAssertTrue(MenuBarFormatter.showsWarning(session: 10, weekly: 95))
        XCTAssertFalse(MenuBarFormatter.showsWarning(session: nil, weekly: nil))
    }
}
