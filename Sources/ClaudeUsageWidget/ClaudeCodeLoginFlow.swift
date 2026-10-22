#if os(macOS)
import Foundation
import AppKit
import CryptoKit
import Darwin
import Observation
import ClaudeUsageCore

/// Drives "Sign in to Claude Code…": opens a `.command` script in Terminal
/// (no Apple Events / Automation permission needed), which runs
/// `claude /login`; watches Claude Code's own credentials for a change, then
/// links this app to Claude Code mode and ends `claude` so Terminal closes
/// the window by itself. Never reads or stores the token itself — only a SHA-256
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
        try? FileManager.default.removeItem(at: Self.pidFileURL())
        state = .idle
    }

    // MARK: - Flow

    private func run() async {
        let initialFingerprint = await Self.fingerprintCredentials()

        let pidFile = Self.pidFileURL()
        Self.prepareForNewRun(pidFile: pidFile)

        let scriptURL: URL
        do {
            scriptURL = try Self.writeLoginScript(pidFile: pidFile)
        } catch {
            state = .failed("Couldn't open Terminal: \(error.localizedDescription)")
            return
        }
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [scriptURL],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, case .waiting = self.state else { return }
                self.pollTask?.cancel()
                self.pollTask = nil
                self.state = .failed("Couldn't open Terminal: \(message)")
            }
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
        // End only the children of the script's shell (i.e. `claude`); the
        // shell then continues to `exit 0` and Terminal closes the window.
        if let pidString = try? String(contentsOf: pidFile, encoding: .utf8) {
            let trimmed = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int32(trimmed), pid > 1 {
                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-TERM", "-P", String(pid)]
                try? pkill.run()
            }
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            // still clean up below
        }
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

    private static func scriptURL() -> URL {
        pidFileURL().deletingLastPathComponent().appendingPathComponent("claude-login.command")
    }

    private static func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the executable `.command` script Terminal will run.
    private static func writeLoginScript(pidFile: URL) throws -> URL {
        let quotedPid = shellQuoted(pidFile.path)
        let script = """
        #!/bin/bash
        clear
        printf '\\n  UsagePet: sign in with your Claude subscription account.\\n  Choose "Claude account with subscription" if asked.\\n  This window closes by itself when you are done.\\n\\n'
        export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
        if ! command -v claude >/dev/null 2>&1; then
          printf '  Claude Code is not installed.\\n  Install it: curl -fsSL https://claude.ai/install.sh | bash\\n\\n'
          read -n 1 -s -r -p "  Press any key to close."
          exit 0
        fi
        echo $$ > \(quotedPid)
        claude /login
        rm -f \(quotedPid)
        exit 0

        """
        let url = scriptURL()
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(
            atPath: url.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

#endif
