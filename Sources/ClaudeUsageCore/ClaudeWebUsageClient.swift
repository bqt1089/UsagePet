import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything that can fetch a `UsageSnapshot` on demand. `UsageStore` holds
/// one of these so it doesn't need to know whether usage comes from a
/// Claude Code OAuth token (`UsageClient`) or a captured claude.ai web
/// session (`ClaudeWebUsageClient`).
public protocol UsageFetching: Sendable {
    func fetch(force: Bool) async throws -> UsageSnapshot
}

extension UsageClient: UsageFetching {}

/// Errors from `ClaudeWebUsageClient.pickOrganization(from:)`.
public enum OrganizationPickError: Error, Sendable, Equatable {
    case invalidJSON
    case empty
}

/// Fetches Claude usage the same way claude.ai's own web app does, using a
/// `sessionKey` cookie captured from an in-app, non-persistent `WKWebView`
/// login (see `ClaudeWebLoginWindow`). This type never reads the system or
/// browser cookie stores, and never logs or prints the session key.
public actor ClaudeWebUsageClient: UsageFetching {

    private let sessionKey: String
    private var orgId: String?
    private let userAgent: String
    private let session: URLSession
    private let minimumInterval: TimeInterval

    private var lastFetchDate: Date?
    private var lastSnapshot: UsageSnapshot?

    /// A normal Safari-like User-Agent, used when the caller doesn't supply
    /// one captured from the login web view.
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    public init(
        sessionKey: String,
        orgId: String? = nil,
        userAgent: String? = nil,
        session: URLSession = UsageClient.makeSession(),
        minimumInterval: TimeInterval = 15
    ) {
        self.sessionKey = sessionKey
        self.orgId = orgId
        self.userAgent = userAgent ?? Self.defaultUserAgent
        self.session = session
        self.minimumInterval = minimumInterval
    }

    /// The organization id in use. If none was supplied at init, discovers
    /// it via `/api/organizations` and caches the result for later calls.
    public func resolvedOrganizationId() async throws -> String {
        if let orgId { return orgId }
        let data = try await requestData(path: "/api/organizations")
        let picked: (uuid: String, name: String?)
        do {
            picked = try Self.pickOrganization(from: data)
        } catch {
            throw UsageClientError.parse
        }
        orgId = picked.uuid
        return picked.uuid
    }

    public func fetch(force: Bool = false) async throws -> UsageSnapshot {
        let now = Date()

        if !force, let lastFetchDate, let lastSnapshot,
           now.timeIntervalSince(lastFetchDate) < minimumInterval {
            return lastSnapshot
        }

        let org = try await resolvedOrganizationId()
        let data = try await requestData(path: "/api/organizations/\(org)/usage")

        let snapshot: UsageSnapshot
        do {
            snapshot = try UsageParser.parse(data, now: now)
        } catch {
            throw UsageClientError.parse
        }

        lastFetchDate = now
        lastSnapshot = snapshot
        return snapshot
    }

    /// Picks the organization to use from a decoded `/api/organizations`
    /// response: the first organization whose `capabilities` array contains
    /// `"chat"`, else the first organization in the list. Pure and
    /// synchronous so it's directly unit-testable.
    ///
    /// - Throws: `.invalidJSON` if the payload isn't a JSON array of
    ///   objects (or no entry has a usable `uuid`), `.empty` if the array is
    ///   empty.
    public static func pickOrganization(from data: Data) throws -> (uuid: String, name: String?) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OrganizationPickError.invalidJSON
        }
        guard let list = object as? [[String: Any]] else {
            throw OrganizationPickError.invalidJSON
        }
        guard !list.isEmpty else {
            throw OrganizationPickError.empty
        }

        func entry(_ item: [String: Any]) -> (uuid: String, name: String?)? {
            guard let uuid = item["uuid"] as? String, !uuid.isEmpty else { return nil }
            return (uuid, item["name"] as? String)
        }

        if let chatItem = list.first(where: { item in
            guard let capabilities = item["capabilities"] as? [String] else { return false }
            return capabilities.contains("chat")
        }), let picked = entry(chatItem) {
            return picked
        }

        for item in list {
            if let picked = entry(item) { return picked }
        }

        throw OrganizationPickError.invalidJSON
    }

    /// Best-effort `/api/account` lookup, for display only (email / name).
    /// Never throws: any failure (network, non-2xx, unexpected JSON) simply
    /// returns nil so callers can treat it as optional.
    public static func fetchAccountInfo(
        sessionKey: String,
        userAgent: String? = nil,
        session: URLSession = UsageClient.makeSession()
    ) async -> (email: String?, name: String?)? {
        guard let url = URL(string: "https://claude.ai/api/account") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue(userAgent ?? defaultUserAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await session.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let email = object["email_address"] as? String
        let name = object["full_name"] as? String
        return (email, name)
    }

    // MARK: - Networking

    private func requestData(path: String) async throws -> Data {
        guard let url = URL(string: "https://claude.ai\(path)") else {
            throw UsageClientError.parse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageClientError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageClientError.network(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
            throw UsageClientError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageClientError.http(httpResponse.statusCode)
        }
    }

    /// Parses a Retry-After header value, which may be either an integer
    /// number of seconds or an HTTP-date. Mirrors `UsageClient`'s parsing.
    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value, !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value) {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }
}
