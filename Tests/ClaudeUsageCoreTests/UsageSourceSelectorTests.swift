import XCTest
@testable import ClaudeUsageCore

final class UsageSourceSelectorTests: XCTestCase {

    private func snapshot(session: Double?, weekly: Double?) -> UsageSnapshot {
        let sessionWindow = session.map {
            UsageWindow(kind: "session", group: "session", fraction: $0, resetsAt: nil, severity: .unknown, isActive: false)
        }
        let weeklyWindow = weekly.map {
            UsageWindow(kind: "weekly_all", group: "weekly", fraction: $0, resetsAt: nil, severity: .unknown, isActive: false)
        }
        return UsageSnapshot(session: sessionWindow, weekly: weeklyWindow, fetchedAt: Date())
    }

    func testPicksHighestMaxFraction() {
        let candidates: [(UsageSource, UsageSnapshot)] = [
            (.claude, snapshot(session: 0.2, weekly: 0.5)),
            (.antigravityGemini, snapshot(session: 0.9, weekly: 0.1)),
            (.antigravityOther, snapshot(session: 0.3, weekly: 0.3))
        ]
        XCTAssertEqual(UsageSourceSelector.tightest(candidates), .antigravityGemini)
    }

    func testTieKeepsEarlierCandidate() {
        let candidates: [(UsageSource, UsageSnapshot)] = [
            (.claude, snapshot(session: 0.5, weekly: 0.1)),
            (.antigravityGemini, snapshot(session: 0.5, weekly: 0.2))
        ]
        XCTAssertEqual(UsageSourceSelector.tightest(candidates), .claude)
    }

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(UsageSourceSelector.tightest([]))
    }

    func testMissingWindowsTreatedAsZero() {
        let candidates: [(UsageSource, UsageSnapshot)] = [
            (.claude, snapshot(session: nil, weekly: nil)),
            (.antigravityGemini, snapshot(session: 0.01, weekly: nil))
        ]
        XCTAssertEqual(UsageSourceSelector.tightest(candidates), .antigravityGemini)
    }
}
