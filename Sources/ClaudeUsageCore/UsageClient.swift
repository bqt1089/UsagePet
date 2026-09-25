import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UsageClientError: Error, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(Error)
    case parse
}

public actor UsageClient {

    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let minimumInterval: TimeInterval

    private var lastFetchDate: Date?
    private var lastSnapshot: UsageSnapshot?

    public init(tokenProvider: TokenProvider, session: URLSession = .shared, minimumInterval: TimeInterval = 15) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.minimumInterval = minimumInterval
    }

    public func fetch(force: Bool = false) async throws -> UsageSnapshot {
        let now = Date()

        if !force, let lastFetchDate, let lastSnapshot,
           now.timeIntervalSince(lastFetchDate) < minimumInterval {
            return lastSnapshot
        }

        let token: String
        do {
            token = try tokenProvider.accessToken()
        } catch {
            throw UsageClientError.network(error)
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UsagePet/0.1.0", forHTTPHeaderField: "User-Agent")

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
            break
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            let retryAfter = parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
            throw UsageClientError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageClientError.http(httpResponse.statusCode)
        }

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

    /// Parses a Retry-After header value, which may be either an integer
    /// number of seconds or an HTTP-date.
    private func parseRetryAfter(_ value: String?) -> TimeInterval? {
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
