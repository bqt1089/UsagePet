#if os(macOS)
import Foundation

/// Renews Claude Code's expired login without user action, by running one
/// tiny `claude -p` in the background: Claude Code refreshes its own token
/// before the request, the normal way, and writes it back to the Keychain.
/// UsagePet itself never touches the refresh token (rotating it here could
/// sign Claude Code out).
///
/// Its token lasts ~8h and only `claude` renews it, so anyone who mostly uses
/// the Claude desktop app would otherwise see usage stop updating every day.
enum ClaudeCodeRenewal {

    /// The prompt is answered by the smallest model with no tools, settings,
    /// MCP servers or saved session: a few dozen tokens per renewal.
    private static let arguments = [
        "claude", "-p", "Reply with OK",
        "--model", "haiku",
        "--no-session-persistence",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--tools", "",
        "--disable-slash-commands",
    ]

    private static let timeout: TimeInterval = 90

    /// Runs `claude -p` off the main thread. True when it exited cleanly.
    static func run() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking())
            }
        }
    }

    private static func runBlocking() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment()
        // An empty folder: no project CLAUDE.md or settings get picked up.
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("UsagePet-renew")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workDir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Apps launched from Finder get a bare PATH, while `claude` usually lives
    /// in a user install dir (native installer, Homebrew, npm/pnpm/nvm/volta/bun).
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath(existing: env["PATH"])
        // Started from inside a Claude Code session (dev runs), these would
        // make the child think it is nested.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return env
    }

    static func searchPath(existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/Library/pnpm",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
        ]
        // npm-global and pnpm shims need `node` on PATH; under nvm that is a
        // versioned dir. Newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs += sorted.map { "\(nvm)/\($0)/bin" }
        }
        dirs.append(existing ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return dirs.joined(separator: ":")
    }
}

#endif
