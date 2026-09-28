import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ClaudeUsageCore

final class ClaudeWebUsageClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - pickOrganization

    func testPickOrganizationPrefersChatCapability() throws {
        let json = """
        [
          {"uuid": "org-1", "name": "No Chat", "capabilities": ["raven"]},
          {"uuid": "org-2", "name": "Has Chat", "capabilities": ["chat", "claude_pro"]}
        ]
        """.data(using: .utf8)!

        let picked = try ClaudeWebUsageClient.pickOrganization(from: json)
        XCTAssertEqual(picked.uuid, "org-2")
        XCTAssertEqual(picked.name, "Has Chat")
    }

    func testPickOrganizationFallsBackToFirstWhenNoCapabilitiesMatch() throws {
        let json = """
        [
          {"uuid": "org-1", "name": "First"},
          {"uuid": "org-2", "name": "Second", "capabilities": ["raven"]}
        ]
        """.data(using: .utf8)!

        let picked = try ClaudeWebUsageClient.pickOrganization(from: json)
        XCTAssertEqual(picked.uuid, "org-1")
        XCTAssertEqual(picked.name, "First")
    }

    func testPickOrganizationThrowsOnEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeWebUsageClient.pickOrganization(from: json)) { error in
            XCTAssertEqual(error as? OrganizationPickError, .empty)
        }
    }

    func testPickOrganizationThrowsOnInvalidJSON() throws {
        let json = "{\"not\": \"an array\"}".data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeWebUsageClient.pickOrganization(from: json)) { error in
            XCTAssertEqual(error as? OrganizationPickError, .invalidJSON)
        }
    }

    // MARK: - fetch()

    func testFetchDiscoversOrgThenParsesLegacyUsageShape() async throws {
        let orgsJSON = """
        [{"uuid": "org-9", "name": "Acme", "capabilities": ["chat"]}]
        """.data(using: .utf8)!

        let usageJSON = """
        {"five_hour": {"utilization": 42, "resets_at": "2026-01-01T00:00:00Z"},
         "seven_day": {"utilization": 57, "resets_at": "2026-01-05T00:00:00Z"}}
        """.data(using: .utf8)!

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: orgsJSON),
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: usageJSON)
        ]

        let client = ClaudeWebUsageClient(sessionKey: "test-session-key", session: makeSession())
        let snapshot = try await client.fetch()

        XCTAssertEqual(snapshot.session?.fraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.fraction ?? -1, 0.57, accuracy: 0.0001)
    }

    func testFetchSkipsOrgDiscoveryWhenOrgIdProvided() async throws {
        let usageJSON = """
        {"five_hour": {"utilization": 10, "resets_at": "2026-01-01T00:00:00Z"}}
        """.data(using: .utf8)!

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: usageJSON)
        ]

        let client = ClaudeWebUsageClient(sessionKey: "test-session-key", orgId: "org-known", session: makeSession())
        let snapshot = try await client.fetch()

        XCTAssertEqual(snapshot.session?.fraction ?? -1, 0.10, accuracy: 0.0001)
    }

    func testUnauthorizedOnOrgDiscoveryThrows() async throws {
        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 401, headers: [:], body: Data())
        ]

        let client = ClaudeWebUsageClient(sessionKey: "expired-session-key", session: makeSession())

        do {
            _ = try await client.fetch()
            XCTFail("expected unauthorized error")
        } catch UsageClientError.unauthorized {
            // expected
        }
    }

    func testRateLimitedOnUsageFetchThrows() async throws {
        let orgsJSON = """
        [{"uuid": "org-9", "name": "Acme", "capabilities": ["chat"]}]
        """.data(using: .utf8)!

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: orgsJSON),
            StubURLProtocol.Response(statusCode: 429, headers: ["Retry-After": "30"], body: Data())
        ]

        let client = ClaudeWebUsageClient(sessionKey: "test-session-key", session: makeSession())

        do {
            _ = try await client.fetch()
            XCTFail("expected rate limited error")
        } catch UsageClientError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        }
    }

    func testMinimumIntervalReturnsCachedSnapshot() async throws {
        let orgsJSON = """
        [{"uuid": "org-9", "name": "Acme", "capabilities": ["chat"]}]
        """.data(using: .utf8)!
        let usageJSON = """
        {"five_hour": {"utilization": 5, "resets_at": "2026-01-01T00:00:00Z"}}
        """.data(using: .utf8)!

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: orgsJSON),
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: usageJSON),
            StubURLProtocol.Response(statusCode: 500, headers: [:], body: Data())
        ]

        let client = ClaudeWebUsageClient(sessionKey: "test-session-key", session: makeSession(), minimumInterval: 15)
        let first = try await client.fetch()
        let second = try await client.fetch()

        XCTAssertEqual(first, second)
    }
}
