import XCTest
@testable import ClaudeUsageCore

final class UsageParserTests: XCTestCase {

    private let referenceNow = ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z")!

    private func fixtureData(_ name: String = "usage_sample", ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    func testParsesRealFixtureFromLimits() throws {
        let data = try fixtureData()
        let snapshot = try UsageParser.parse(data, now: referenceNow)

        let session = try XCTUnwrap(snapshot.session)
        XCTAssertEqual(session.fraction, 0.42, accuracy: 0.0001)
        XCTAssertEqual(session.isActive, false)
        XCTAssertEqual(session.severity, .normal)
        let expectedSessionReset = ISO8601DateFormatter().date(from: "2026-09-24T03:00:00Z")!
        let sessionReset = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(sessionReset.timeIntervalSince1970, expectedSessionReset.timeIntervalSince1970, accuracy: 1)

        let weekly = try XCTUnwrap(snapshot.weekly)
        XCTAssertEqual(weekly.fraction, 0.57, accuracy: 0.0001)
        XCTAssertEqual(weekly.isActive, true)
        XCTAssertEqual(weekly.severity, .normal)
        let expectedWeeklyReset = ISO8601DateFormatter().date(from: "2026-09-29T21:00:00Z")!
        let weeklyReset = try XCTUnwrap(weekly.resetsAt)
        XCTAssertEqual(weeklyReset.timeIntervalSince1970, expectedWeeklyReset.timeIntervalSince1970, accuracy: 1)
    }

    func testFallsBackToFiveHourAndSevenDayWhenLimitsMissing() throws {
        let data = try fixtureData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "limits")
        let modified = try JSONSerialization.data(withJSONObject: json)

        let snapshot = try UsageParser.parse(modified, now: referenceNow)

        let session = try XCTUnwrap(snapshot.session)
        XCTAssertEqual(session.fraction, 0.42, accuracy: 0.0001)

        let weekly = try XCTUnwrap(snapshot.weekly)
        XCTAssertEqual(weekly.fraction, 0.57, accuracy: 0.0001)
    }

    func testFallsBackWhenLimitsIsEmptyArray() throws {
        let data = try fixtureData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["limits"] = [Any]()
        let modified = try JSONSerialization.data(withJSONObject: json)

        let snapshot = try UsageParser.parse(modified, now: referenceNow)
        XCTAssertNotNil(snapshot.session)
        XCTAssertNotNil(snapshot.weekly)
    }

    /// Regression: percent 1 (1%) used to be read as a fraction and shown as 100%.
    func testSmallPercentValuesAreNotTreatedAsFractions() throws {
        let json: [String: Any] = [
            "limits": [
                ["kind": "session", "group": "session", "percent": 1, "severity": "normal", "resets_at": NSNull(), "is_active": false],
                ["kind": "weekly_all", "group": "weekly", "percent": 0.5, "severity": "normal", "resets_at": NSNull(), "is_active": true]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try UsageParser.parse(data, now: referenceNow)

        XCTAssertEqual(snapshot.session?.fraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.fraction ?? -1, 0.005, accuracy: 0.0001)
    }

    func testAcceptsEpochSecondsAndMillisecondsForResetsAt() throws {
        let epochSeconds: TimeInterval = 1_790_000_000
        let epochMillis = epochSeconds * 1000

        let json: [String: Any] = [
            "limits": [
                ["kind": "session", "group": "session", "percent": 10, "severity": "normal", "resets_at": epochSeconds, "is_active": false],
                ["kind": "weekly_all", "group": "weekly", "percent": 20, "severity": "normal", "resets_at": epochMillis, "is_active": false]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try UsageParser.parse(data, now: referenceNow)

        XCTAssertEqual(snapshot.session?.resetsAt?.timeIntervalSince1970 ?? -1, epochSeconds, accuracy: 1)
        XCTAssertEqual(snapshot.weekly?.resetsAt?.timeIntervalSince1970 ?? -1, epochSeconds, accuracy: 1)
    }

    func testToleratesGarbageAndUnknownKeys() throws {
        let json: [String: Any] = [
            "some_new_field_from_the_future": ["nested": [1, 2, 3]],
            "limits": [
                [
                    "kind": "session", "group": "session", "percent": 15,
                    "severity": "some_totally_unknown_severity",
                    "resets_at": "2026-09-24T03:00:00.123456789+00:00",
                    "is_active": false,
                    "codename": "ignored", "scope": NSNull()
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try UsageParser.parse(data, now: referenceNow)

        let session = try XCTUnwrap(snapshot.session)
        XCTAssertEqual(session.severity, .unknown)
        XCTAssertNotNil(session.resetsAt)
    }

    func testThrowsWhenBothWindowsMissing() {
        let json: [String: Any] = ["something_else": true]
        let data = try! JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try UsageParser.parse(data, now: referenceNow)) { error in
            XCTAssertEqual(error as? UsageParseError, .missingWindows)
        }
    }

    func testThrowsOnInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try UsageParser.parse(data, now: referenceNow)) { error in
            XCTAssertEqual(error as? UsageParseError, .invalidJSON)
        }
    }
}
