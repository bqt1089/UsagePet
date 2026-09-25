import Foundation

public enum TokenProviderError: Error, Sendable, Equatable {
    case notFound
    case invalidCredentialsFile
}

public protocol TokenProvider: Sendable {
    func accessToken() throws -> String
}

/// Resolves a Claude Code OAuth access token, in order:
/// 1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable.
/// 2. macOS Keychain entry "Claude Code-credentials" (via `/usr/bin/security`).
/// 3. `$CLAUDE_CONFIG_DIR/.credentials.json` or `~/.claude/.credentials.json`.
///
/// The token is never logged, printed, or persisted by this type.
public struct ClaudeCodeTokenProvider: TokenProvider {

    public private(set) var expiresAt: Date?

    public init() {}

    public func accessToken() throws -> String {
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !envToken.isEmpty {
            return envToken
        }

        #if os(macOS)
        if let keychainToken = try? readFromKeychain() {
            return keychainToken
        }
        #endif

        if let fileToken = try? readFromCredentialsFile() {
            return fileToken
        }

        throw TokenProviderError.notFound
    }

    /// Best-effort lookup of the token's expiry, reading the same sources as
    /// `accessToken()`. Returns nil when no expiry is available.
    public func currentExpiresAt() -> Date? {
        guard let credentials = try? loadCredentialsPayload() else { return nil }
        return credentials.expiresAt
    }

    #if os(macOS)
    private func readFromKeychain() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TokenProviderError.notFound
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard var token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw TokenProviderError.notFound
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)

        // Keychain value may itself be the credentials JSON blob.
        if token.hasPrefix("{"), let jsonData = token.data(using: .utf8) {
            let credentials = try parseCredentials(jsonData)
            return credentials.accessToken
        }

        guard !token.isEmpty else { throw TokenProviderError.notFound }
        return token
    }
    #endif

    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
    }

    private func credentialsFileURL() -> URL {
        let fileManager = FileManager.default
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            return URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/.credentials.json")
    }

    private func readFromCredentialsFile() throws -> String {
        let credentials = try loadCredentialsPayload()
        return credentials.accessToken
    }

    private func loadCredentialsPayload() throws -> Credentials {
        let url = credentialsFileURL()
        let data = try Data(contentsOf: url)
        return try parseCredentials(data)
    }

    private func parseCredentials(_ data: Data) throws -> Credentials {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            throw TokenProviderError.invalidCredentialsFile
        }

        var expiresAt: Date?
        if let expiresAtMs = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000.0)
        } else if let expiresAtMs = oauth["expiresAt"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(expiresAtMs) / 1000.0)
        }

        return Credentials(accessToken: accessToken, expiresAt: expiresAt)
    }
}

/// A `TokenProvider` backed by a closure, so callers can supply a fixed
/// token or re-read a mutable source (e.g. this app's own Keychain item)
/// on every call without needing a new provider type per source.
public struct StaticTokenProvider: TokenProvider {
    private let provideToken: @Sendable () -> String?

    /// Always returns the same fixed token.
    public init(token: String) {
        self.provideToken = { token }
    }

    /// Re-invokes `provider` on every `accessToken()` call, so it can read a
    /// value that changes over time (e.g. a Keychain item).
    public init(_ provider: @escaping @Sendable () -> String?) {
        self.provideToken = provider
    }

    public func accessToken() throws -> String {
        guard let token = provideToken(), !token.isEmpty else {
            throw TokenProviderError.notFound
        }
        return token
    }
}
