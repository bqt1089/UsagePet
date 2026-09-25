import XCTest
@testable import ClaudeUsageCore

final class AntigravityQuotaParserTests: XCTestCase {

    private let referenceNow = ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z")!

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "antigravity_quota_sample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testParsesGeminiGroup() throws {
        let groups = try AntigravityQuotaParser.parse(fixtureData(), now: referenceNow)
        let gemini = try XCTUnwrap(groups.first { $0.id == "gemini" })
        XCTAssertEqual(gemini.displayName, "Gemini Models")

        let session = try XCTUnwrap(gemini.snapshot.session)
        XCTAssertEqual(session.fraction, 0.0, accuracy: 0.0001)
        XCTAssertEqual(session.kind, "session")

        let weekly = try XCTUnwrap(gemini.snapshot.weekly)
        XCTAssertEqual(weekly.fraction, 0.13307, accuracy: 0.0001)
        XCTAssertEqual(weekly.kind, "weekly_all")
        let expectedReset = ISO8601DateFormatter().date(from: "2026-09-30T02:54:18Z")!
        let reset = try XCTUnwrap(weekly.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 1)
    }

    func testParsesThirdPartyGroup() throws {
        let groups = try AntigravityQuotaParser.parse(fixtureData(), now: referenceNow)
        let thirdParty = try XCTUnwrap(groups.first { $0.id == "3p" })
        XCTAssertEqual(thirdParty.displayName, "Claude and GPT models")

        let weekly = try XCTUnwrap(thirdParty.snapshot.weekly)
        XCTAssertEqual(weekly.fraction, 0.27095, accuracy: 0.0001)

        let session = try XCTUnwrap(thirdParty.snapshot.session)
        XCTAssertEqual(session.fraction, 0.0, accuracy: 0.0001)
    }

    func testMissingRemainingFractionYieldsNilWindow() throws {
        let json: [String: Any] = [
            "response": [
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            ["bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2026-09-30T02:54:18Z"],
                            ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let groups = try AntigravityQuotaParser.parse(data, now: referenceNow)
        let gemini = try XCTUnwrap(groups.first { $0.id == "gemini" })
        XCTAssertNil(gemini.snapshot.weekly)
        XCTAssertNotNil(gemini.snapshot.session)
    }

    func testUnknownKeysAreIgnored() throws {
        let json: [String: Any] = [
            "response": [
                "somethingElse": "ignored",
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "extraField": 42,
                        "buckets": [
                            ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5, "weirdField": true]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let groups = try AntigravityQuotaParser.parse(data, now: referenceNow)
        let gemini = try XCTUnwrap(groups.first { $0.id == "gemini" })
        XCTAssertEqual(gemini.snapshot.session?.fraction ?? -1, 0.5, accuracy: 0.0001)
    }

    func testGarbageThrows() {
        let data = Data("not json at all {{{".utf8)
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(data, now: referenceNow))
    }

    func testMissingGroupsThrows() {
        let json: [String: Any] = ["response": ["description": "no groups here"]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(data, now: referenceNow)) { error in
            XCTAssertEqual(error as? AntigravityParseError, .missingGroups)
        }
    }
}
