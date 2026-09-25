import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityClientError: Error, Sendable, Equatable {
    /// No running Antigravity language server process was found (app not
    /// open, or it doesn't expose `--csrf_token` the way we expect).
    case notRunning
    /// The server responded, but not the way we expect (e.g. its method
    /// name or auth scheme changed). Carries the HTTP status code.
    case protocolChanged(Int)
    /// The response body wasn't the JSON shape `AntigravityQuotaParser`
    /// understands.
    case parse
    /// A connection-level failure (couldn't reach 127.0.0.1:<port> at all).
    case network
}

/// Talks to the Antigravity desktop app's own local language-server
/// process, entirely over `127.0.0.1`, read-only. Discovers the process via
/// `ps`/`lsof` (macOS only — see `discoverProcessIfNeeded`), caches its
/// pid/token/port, and polls the same quota endpoint the app itself uses.
/// The CSRF token is never logged or printed.
public actor AntigravityClient {

    private let minimumInterval: TimeInterval
    private var lastFetchDate: Date?
    private var lastGroups: [ProviderGroupUsage]?

    #if os(macOS)
    private var cachedPid: Int32?
    private var cachedToken: String?
    private var cachedPort: Int?
    private let session: URLSession
    #endif

    public init(minimumInterval: TimeInterval = 15) {
        self.minimumInterval = minimumInterval
        #if os(macOS)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        self.session = URLSession(configuration: config, delegate: AntigravityTrustDelegate(), delegateQueue: nil)
        #endif
    }

    /// Fetches quota groups for every Antigravity model group. Cached for
    /// `minimumInterval` seconds unless `force` is true, matching
    /// `UsageClient`'s cadence.
    public func fetchGroups(force: Bool = false) async throws -> [ProviderGroupUsage] {
        #if os(macOS)
        let now = Date()
        if !force, let lastFetchDate, let lastGroups,
           now.timeIntervalSince(lastFetchDate) < minimumInterval {
            return lastGroups
        }

        do {
            let groups = try await performFetch(now: now)
            lastFetchDate = now
            lastGroups = groups
            return groups
        } catch {
            if shouldRediscover(error) {
                clearCache()
                let groups = try await performFetch(now: now)
                lastFetchDate = now
                lastGroups = groups
                return groups
            }
            throw error
        }
        #else
        throw AntigravityClientError.notRunning
        #endif
    }

    #if os(macOS)

    private func shouldRediscover(_ error: Error) -> Bool {
        switch error {
        case AntigravityClientError.network:
            return true
        case AntigravityClientError.protocolChanged(401), AntigravityClientError.protocolChanged(404):
            return true
        default:
            return false
        }
    }

    private func clearCache() {
        cachedPid = nil
        cachedToken = nil
        cachedPort = nil
    }

    private func performFetch(now: Date) async throws -> [ProviderGroupUsage] {
        let (pid, token) = try discoverProcessIfNeeded()
        let port = try await discoverPortIfNeeded(pid: pid, token: token)
        let data = try await postQuotaRequest(port: port, token: token)
        do {
            return try AntigravityQuotaParser.parse(data, now: now)
        } catch {
            throw AntigravityClientError.parse
        }
    }

    private func discoverProcessIfNeeded() throws -> (pid: Int32, token: String) {
        if let cachedPid, let cachedToken {
            return (cachedPid, cachedToken)
        }
        guard let line = Self.runPS(),
              let (pid, token) = AntigravityProcessInfo.parse(psLine: line) else {
            throw AntigravityClientError.notRunning
        }
        cachedPid = pid
        cachedToken = token
        return (pid, token)
    }

    /// Tries each listening port in turn until one answers the quota
    /// endpoint with HTTP 200, caching the winner.
    private func discoverPortIfNeeded(pid: Int32, token: String) async throws -> Int {
        if let cachedPort {
            return cachedPort
        }
        guard let lsofOutput = Self.runLsof(pid: pid) else {
            throw AntigravityClientError.notRunning
        }
        let ports = AntigravityProcessInfo.parseListenPorts(lsofOutput: lsofOutput)
        guard !ports.isEmpty else { throw AntigravityClientError.notRunning }

        for candidate in ports {
            if (try? await postQuotaRequest(port: candidate, token: token)) != nil {
                cachedPort = candidate
                return candidate
            }
        }
        throw AntigravityClientError.notRunning
    }

    private func postQuotaRequest(port: Int, token: String) async throws -> Data {
        guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            throw AntigravityClientError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AntigravityClientError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityClientError.network
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw AntigravityClientError.protocolChanged(401)
        case 404:
            throw AntigravityClientError.protocolChanged(404)
        default:
            throw AntigravityClientError.protocolChanged(httpResponse.statusCode)
        }
    }

    private static func runPS() -> String? {
        guard let output = runProcess("/bin/ps", ["-axww", "-o", "pid=,command="]) else { return nil }
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            if lower.contains("--csrf_token"), lower.contains("antigravity") {
                return String(line)
            }
        }
        return nil
    }

    private static func runLsof(pid: Int32) -> String? {
        runProcess("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", String(pid)])
    }

    /// Runs a fixed-path executable off the main thread (this whole actor
    /// is off-main already) and returns its stdout as a UTF-8 string, or
    /// nil on any failure. Never throws — process discovery is best-effort.
    private static func runProcess(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    #endif
}

#if os(macOS)
/// Accepts the Antigravity language server's self-signed TLS certificate,
/// but ONLY for connections to `127.0.0.1`; every other host falls back to
/// the system's normal certificate validation.
final class AntigravityTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.host == "127.0.0.1",
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
#endif
