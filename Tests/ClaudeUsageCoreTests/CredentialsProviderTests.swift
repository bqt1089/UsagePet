import XCTest
@testable import ClaudeUsageCore

final class CredentialsProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func credentialsJSON(expiresAtMs: Double?) -> Data {
        var oauth: [String: Any] = ["accessToken": "tok-123"]
        if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    func testReturnsTokenBeforeExpiry() throws {
        let data = credentialsJSON(expiresAtMs: (now.timeIntervalSince1970 + 3600) * 1000)
        XCTAssertEqual(try ClaudeCodeTokenProvider.accessToken(fromCredentialsJSON: data, now: now), "tok-123")
    }

    func testThrowsExpiredAfterExpiry() {
        let data = credentialsJSON(expiresAtMs: (now.timeIntervalSince1970 - 1) * 1000)
        XCTAssertThrowsError(try ClaudeCodeTokenProvider.accessToken(fromCredentialsJSON: data, now: now)) { error in
            XCTAssertEqual(error as? TokenProviderError, .expired)
        }
    }

    func testMissingExpiryIsTreatedAsValid() throws {
        let data = credentialsJSON(expiresAtMs: nil)
        XCTAssertEqual(try ClaudeCodeTokenProvider.accessToken(fromCredentialsJSON: data, now: now), "tok-123")
    }

    func testMalformedJSONIsInvalid() {
        XCTAssertThrowsError(try ClaudeCodeTokenProvider.accessToken(fromCredentialsJSON: Data("{}".utf8), now: now)) { error in
            XCTAssertEqual(error as? TokenProviderError, .invalidCredentialsFile)
        }
    }
}
