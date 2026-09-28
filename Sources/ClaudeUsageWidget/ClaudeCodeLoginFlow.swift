#if os(macOS)
import Foundation
import AppKit
import CryptoKit
import Darwin
import Observation
import ClaudeUsageCore

/// Drives "Sign in to Claude Code…": opens Terminal, runs `claude /login`
/// there, watches Claude Code's own credentials for a change, then links
/// this app to Claude Code mode and closes the Terminal window
/// automatically. Never reads or stores the token itself — only a SHA-256
/// fingerprint of it, kept in memory for the duration of one flow.
@MainActor
@Observable
final class ClaudeCodeLoginFlow {

    enum State: Equatable {
        case idle
        case waiting(startedAt: Date)
        case succeeded
        case failed(String)
    }

    static let shared = ClaudeCodeLoginFlow()

    private(set) var state: State = .idle

    /// Set once by `AppDelegate` at launch so `start()` (called with no
    /// arguments from the widget/Settings) has an `AccountManager` to link
    /// on success. Weak: this flow outlives no particular window/app run.
    private weak var accountManager: AccountManager?

    private var pollTask: Task<Void, Never>?
    private var terminalWindowId: Int?

    private static let pollInterval: TimeInterval = 2
    private static let timeout: TimeInterval = 300 // 5 minutes
    private static let successDisplayDuration: TimeInterval = 3

    private init() {}

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func attach(accountManager: AccountManager) {
        self.accountManager = accountManager
    }

    /// Opens Terminal and runs `claude /login`, then polls Claude Code's
    /// credentials for a change. Safe to call again while already waiting
    /// (it's a no-op then); call `cancel()` first to force a restart.
    func start() {
        if case .waiting = state { return }
        pollTask?.cancel()
        terminalWindowId = nil
        state = .waiting(startedAt: Date())
        pollTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops polling and returns to `.idle`. Does not touch the Terminal
    /// window — the user may still be signing in there.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        state = .idle
    }

    // MARK: - Flow

    private func run() async {
        let initialFingerprint = await Self.fingerprintCredentials()

        let pidFile = Self.pidFileURL()
        Self.prepareForNewRun(pidFile: pidFile)

        let shellCommand = Self.buildShellCommand(pidFilePath: pidFile.path)
        switch Self.openTerminal(runningShellCommand: shellCommand) {
        case .failure(let error):
            state = .failed("Couldn't open Terminal: \(error.message)")
            return
        case .success(let windowId):
            terminalWindowId = windowId
        }

        ClaudeCodeTokenProvider.interactiveUntil = Date().addingTimeInterval(Self.timeout)

        let deadline = Date().addingTimeInterval(Self.timeout)
        // A single sequential loop: each tick awaits its own fingerprint
        // read to completion before sleeping again, so reads never overlap.
        while Date() < deadline {
            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            } catch {
                return
            }
            if Task.isCancelled { return }

            let fingerprint = await Self.fingerprintCredentials()
            if let fingerprint, fingerprint != initialFingerprint {
                await finishSuccess(pidFile: pidFile)
                return
            }
        }

        state = .failed("Timed out waiting for sign-in. Try again.")
    }

    private func finishSuccess(pidFile: URL) async {
        accountManager?.useClaudeCodeLogin()
        await closeTerminal(pidFile: pidFile)
        state = .succeeded

        do {
            try await Task.sleep(nanoseconds: UInt64(Self.successDisplayDuration * 1_000_000_000))
        } catch {
            return
        }
        if case .succeeded = state {
            state = .idle
        }
    }

    private func closeTerminal(pidFile: URL) async {
        if let pidString = try? String(contentsOf: pidFile, encoding: .utf8) {
            let trimmed = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int32(trimmed) {
                kill(pid, SIGTERM)
            }
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            // still try to clean up below
        }

        if let windowId = terminalWindowId {
            let closeScript = """
            tell application "Terminal"
                try
                    close (every window whose id is \(windowId)) saving no
                end try
            end tell
            """
            _ = Self.runAppleScript(closeScript)
        }
        terminalWindowId = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - Credentials fingerprint

    /// SHA-256 hex digest of the current Claude Code access token, or nil
    /// if there is none (or reading it failed). Never stores or logs the
    /// token itself. Runs off the main actor so a slow/hanging Keychain
    /// read never blocks the UI.
    private static func fingerprintCredentials() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let provider = ClaudeCodeTokenProvider()
            guard let token = try? provider.accessToken(), !token.isEmpty else { return nil }
            let digest = SHA256.hash(data: Data(token.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: - Terminal / pid file

    private static func pidFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppKeychain.service)", isDirectory: true)
            .appendingPathComponent("claude-login.pid")
    }

    private static func prepareForNewRun(pidFile: URL) {
        let dir = pidFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func buildShellCommand(pidFilePath: String) -> String {
        """
        clear; printf '\\n  UsagePet: sign in with your Claude subscription account.\\n  Choose "Claude account with subscription" if asked.\\n  This window closes automatically when done.\\n\\n'; if command -v claude >/dev/null 2>&1; then echo $$ > '\(pidFilePath)'; exec claude /login; else printf '  Claude Code is not installed.\\n  Install: curl -fsSL https://claude.ai/install.sh | bash\\n  or use "Sign in with claude.ai\u{2026}" in UsagePet.\\n'; fi
        """
    }

    /// Opens (or reuses) a Terminal window running `command`, returning the
    /// window's id so it can be closed again once sign-in finishes.
    private static func openTerminal(runningShellCommand command: String) -> Result<Int, AppleScriptError> {
        let escaped = escapeForAppleScriptString(command)
        let source = """
        tell application "Terminal"
            activate
            set t to do script "\(escaped)"
            try
                return id of (first window whose tabs contains t)
            on error
                return id of front window
            end try
        end tell
        """
        return runAppleScript(source)
    }

    private static func escapeForAppleScriptString(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Result<Int, AppleScriptError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(AppleScriptError(message: "couldn't compile AppleScript"))
        }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            return .failure(AppleScriptError(message: message))
        }
        let windowId = Int(result.int32Value)
        guard windowId != 0 else {
            return .failure(AppleScriptError(message: "no Terminal window id returned"))
        }
        return .success(windowId)
    }
}

#endif

struct AppleScriptError: Error {
    let message: String
}
