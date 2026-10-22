import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ClaudeUsageCore

private struct FakeTokenProvider: TokenProvider {
    let token: String
    func accessToken() throws -> String { token }
}

private struct ThrowingTokenProvider: TokenProvider {
    func accessToken() throws -> String { throw TokenProviderError.notFound }
}

/// Stubs network responses for a single fixed URL, keyed by call order.
final class StubURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    static var responses: [Response] = []
    private static var callIndex = 0

    static func reset() {
        responses = []
        callIndex = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = min(Self.callIndex, Self.responses.count - 1)
        Self.callIndex += 1
        let stub = Self.responses[max(index, 0)]

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UsageClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSuccessfulFetchParsesSnapshot() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "usage_sample", withExtension: "json"))
        let body = try Data(contentsOf: fixtureURL)

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: body)
        ]

        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "test-token"), session: makeSession())
        let snapshot = try await client.fetch()

        XCTAssertEqual(snapshot.session?.fraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.fraction ?? -1, 0.57, accuracy: 0.0001)
    }

    func testUnauthorizedThrows() async throws {
        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 401, headers: [:], body: Data())
        ]

        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "bad-token"), session: makeSession())

        do {
            _ = try await client.fetch()
            XCTFail("expected unauthorized error")
        } catch UsageClientError.unauthorized {
            // expected
        }
    }

    func testRateLimitedParsesRetryAfterSeconds() async throws {
        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 429, headers: ["Retry-After": "120"], body: Data())
        ]

        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "token"), session: makeSession())

        do {
            _ = try await client.fetch()
            XCTFail("expected rate limited error")
        } catch UsageClientError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        }
    }

    func testRateLimitWindowSurvivesClientRebuild() async throws {
        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 429, headers: ["Retry-After": "600"], body: Data()),
            StubURLProtocol.Response(statusCode: 500, headers: [:], body: Data())
        ]
        let gate = RateLimitGate()

        let first = UsageClient(tokenProvider: FakeTokenProvider(token: "token"), session: makeSession(), rateLimitGate: gate)
        do { _ = try await first.fetch(force: true); XCTFail("expected rate limited") } catch UsageClientError.rateLimited {}

        // A rebuilt client (wake / watchdog / Refresh Now) must not send a
        // request while the window is open: it would get the 500 stub.
        let rebuilt = UsageClient(tokenProvider: FakeTokenProvider(token: "token"), session: makeSession(), rateLimitGate: gate)
        do {
            _ = try await rebuilt.fetch(force: true)
            XCTFail("expected rate limited")
        } catch UsageClientError.rateLimited(let retryAfter) {
            XCTAssertGreaterThan(retryAfter ?? 0, 590)
        }
    }

    func testRateLimitGateOpensAfterWindow() {
        let gate = RateLimitGate()
        let now = Date()
        gate.block(for: 30, now: now)
        XCTAssertNotNil(gate.remaining(now: now.addingTimeInterval(29)))
        XCTAssertNil(gate.remaining(now: now.addingTimeInterval(31)))
        gate.block(for: 30, now: now)
        gate.clear()
        XCTAssertNil(gate.remaining(now: now))
    }

    func testMinimumIntervalReturnsCachedSnapshot() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "usage_sample", withExtension: "json"))
        let body = try Data(contentsOf: fixtureURL)

        StubURLProtocol.responses = [
            StubURLProtocol.Response(statusCode: 200, headers: [:], body: body),
            StubURLProtocol.Response(statusCode: 500, headers: [:], body: Data())
        ]

        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "token"), session: makeSession(), minimumInterval: 15)
        let first = try await client.fetch()
        // Second call within the minimum interval should return cached result
        // without hitting the (failing) second stub response.
        let second = try await client.fetch()

        XCTAssertEqual(first, second)
    }

    func testMissingTokenSurfacesAsNetworkError() async throws {
        let client = UsageClient(tokenProvider: ThrowingTokenProvider(), session: makeSession())

        do {
            _ = try await client.fetch()
            XCTFail("expected an error")
        } catch UsageClientError.network {
            // expected
        }
    }
}
