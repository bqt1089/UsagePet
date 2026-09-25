import XCTest
@testable import ClaudeUsageCore

final class MoodEngineTests: XCTestCase {

    private func input(
        session: Double? = nil,
        weekly: Double? = nil,
        linked: Bool = true,
        offline: Bool = false,
        rateLimited: Bool = false,
        claudeActive: Bool = false,
        localHour: Int = 12,
        event: MoodInput.ActiveEvent = .none
    ) -> MoodInput {
        MoodInput(
            sessionFraction: session,
            weeklyFraction: weekly,
            linked: linked,
            offline: offline,
            rateLimited: rateLimited,
            claudeActive: claudeActive,
            localHour: localHour,
            activeEvent: event
        )
    }

    // MARK: - Rule 5: 5h Current thresholds

    func testEcstaticBelow10Percent() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.0)), .ecstatic)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.09)), .ecstatic)
    }

    func testHappy10To40() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.10)), .happy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.39)), .happy)
    }

    func testChill40To60() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.40)), .chill)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.59)), .chill)
    }

    func testFocused60To80() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.60)), .focused)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.79)), .focused)
    }

    func testWorried80To90() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.80)), .worried)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.89)), .worried)
    }

    func testStressed90To95() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.90)), .stressed)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.94)), .stressed)
    }

    func testPanic95To99() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.95)), .panic)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.99)), .panic)
    }

    func testSleepingAt100() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 1.0)), .sleeping)
    }

    func testMissingSessionFractionDefaultsToEcstatic() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: nil)), .ecstatic)
    }

    // MARK: - Claude active / night sleepy rules

    func testClaudeActiveGivesTypingWhenBelowWorriedThreshold() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.50, claudeActive: true)), .typing)
    }

    func testHighUsageBeatsClaudeActive() {
        // Worried/stressed/panic/sleeping take priority over "typing".
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.85, claudeActive: true)), .worried)
    }

    func testNightAndLowUsageIsSleepy() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 23)), .sleepy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 2)), .sleepy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 4)), .sleepy)
    }

    func testNightButHighUsageIsNotSleepy() {
        // cur >= 60 wins over the night rule per priority order.
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.65, localHour: 23)), .focused)
    }

    func testDayHourIsNeverSleepyRegardlessOfUsage() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 12)), .happy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 5)), .happy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, localHour: 22)), .happy)
    }

    func testClaudeActiveBeatsSleepyAtNight() {
        // "Claude Code active -> typing" is checked before the night rule.
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, claudeActive: true, localHour: 23)), .typing)
    }

    // MARK: - Rule 4: not linked / offline / rate limited

    func testNotLinkedIsLonelyRegardlessOfUsage() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.99, linked: false)), .lonely)
    }

    func testOfflineIsDizzy() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.50, offline: true)), .dizzy)
    }

    func testRateLimitedIsConfused() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.50, rateLimited: true)), .confused)
    }

    func testNotLinkedBeatsOfflineAndRateLimited() {
        XCTAssertEqual(MoodEngine.pick(input: input(linked: false, offline: true, rateLimited: true)), .lonely)
    }

    func testOfflineBeatsRateLimited() {
        XCTAssertEqual(MoodEngine.pick(input: input(offline: true, rateLimited: true)), .dizzy)
    }

    // MARK: - Rule 3: weekly >= 100% -> vacation

    func testWeeklyFullIsVacationEvenAtHighCurrent() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.97, weekly: 1.0)), .vacation)
    }

    func testWeeklyFullBeatsNotLinkedOfflineRateLimited() {
        XCTAssertEqual(MoodEngine.pick(input: input(weekly: 1.0, linked: false)), .vacation)
        XCTAssertEqual(MoodEngine.pick(input: input(weekly: 1.0, offline: true)), .vacation)
        XCTAssertEqual(MoodEngine.pick(input: input(weekly: 1.0, rateLimited: true)), .vacation)
    }

    func testWeeklyBelow100NeverTriggersVacationAndPetFollowsCurrent() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, weekly: 0.85)), .happy)
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, weekly: 0.99)), .happy)
    }

    // MARK: - Rule 2: reset events

    func testSessionResetEventIsCelebrateRegardlessOfOtherState() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.95, event: .sessionReset)), .celebrate)
    }

    func testWeeklyResetEventIsLoveRegardlessOfOtherState() {
        XCTAssertEqual(MoodEngine.pick(input: input(weekly: 1.0, event: .weeklyReset)), .love)
    }

    func testSessionResetEventBeatsWeeklyVacation() {
        XCTAssertEqual(MoodEngine.pick(input: input(weekly: 1.0, event: .sessionReset)), .celebrate)
    }

    func testResetEventBeatsNotLinkedOfflineRateLimited() {
        XCTAssertEqual(MoodEngine.pick(input: input(linked: false, event: .sessionReset)), .celebrate)
        XCTAssertEqual(MoodEngine.pick(input: input(offline: true, event: .weeklyReset)), .love)
        XCTAssertEqual(MoodEngine.pick(input: input(rateLimited: true, event: .sessionReset)), .celebrate)
    }

    // MARK: - WeeklyAlert border level (independent of pet mood)

    func testWeeklyAlertLevels() {
        XCTAssertEqual(WeeklyAlert.level(0.0), .none)
        XCTAssertEqual(WeeklyAlert.level(0.59), .none)
        XCTAssertEqual(WeeklyAlert.level(0.60), .yellow)
        XCTAssertEqual(WeeklyAlert.level(0.79), .yellow)
        XCTAssertEqual(WeeklyAlert.level(0.80), .orange)
        XCTAssertEqual(WeeklyAlert.level(0.94), .orange)
        XCTAssertEqual(WeeklyAlert.level(0.95), .red)
        XCTAssertEqual(WeeklyAlert.level(0.99), .red)
        XCTAssertEqual(WeeklyAlert.level(1.0), .none)
    }

    func testWeeklyAlertOrangeAtEightyWithLowCurrentDoesNotAffectMood() {
        XCTAssertEqual(MoodEngine.pick(input: input(session: 0.30, weekly: 0.85)), .happy)
        XCTAssertEqual(WeeklyAlert.level(0.85), .orange)
    }
}
