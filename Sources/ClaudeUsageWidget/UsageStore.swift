#if os(macOS)
import Foundation
import AppKit
import Observation
import ClaudeUsageCore

/// Observable app-facing state for the usage widget. Owns the poll loop and
/// exposes a small status enum the UI renders from. All mutable state is
/// confined to the main actor; the underlying `UsageClient` is an actor and
/// safe to call from here.
@MainActor
@Observable
final class UsageStore {

    enum Status: Equatable {
        case loading
        case ok
        case stale(since: Date)
        case rateLimited(until: Date?)
        case needsLogin(message: String)
        case error(String)
    }

    let accountManager: AccountManager

    private(set) var snapshot: UsageSnapshot?
    private(set) var status: Status = .loading
    private(set) var lastUpdated: Date?

    /// Ticks once a second so countdown/"updated Xs ago" text stays live
    /// without re-fetching.
    private(set) var now: Date = Date()

    /// True when a `.jsonl` file under `~/.claude/projects/**` was modified
    /// within the last 60 seconds — a cheap, no-token-access proxy for
    /// "Claude Code is actively running". Refreshed at most every 10s, off
    /// the main thread.
    private(set) var claudeActive: Bool = false

    /// True only when the most recent fetch failed with a genuine
    /// network/connection error (`UsageClientError.network`), as opposed to
    /// an HTTP/parse error or an expired token.
    private(set) var lastErrorWasNetwork: Bool = false

    /// Set right after detecting a session/weekly reset transition; expires
    /// automatically after `Self.eventDuration` (see `currentActiveEvent`).
    private(set) var detectedEvent: MoodInput.ActiveEvent = .none
    private var eventExpiry: Date?
    private static let eventDuration: TimeInterval = 3.5

    /// Settings > Appearance debug-only pinned mood preview. `nil` means
    /// "follow the real mood engine" (the normal path).
    var debugPinnedMood: PetMood?

    private var client: UsageClient
    private var scheduler = PollScheduler()
    private var pollTask: Task<Void, Never>?
    private var claudeActiveTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var accountModeObserver: NSObjectProtocol?
    private var started = false

    init(accountManager: AccountManager) {
        self.accountManager = accountManager
        self.client = Self.makeClient(for: accountManager)
    }

    private static func makeClient(for accountManager: AccountManager) -> UsageClient {
        guard let provider = accountManager.makeTokenProvider() else {
            // No mode selected yet; this client is never actually polled
            // against (see `restartPolling`), but give it something inert.
            return UsageClient(tokenProvider: StaticTokenProvider { nil })
        }
        return UsageClient(tokenProvider: provider)
    }

    // MARK: - Pixel Pet mood inputs

    /// Whether an event set by `detectedEvent` is still within its display
    /// window; falls back to `.none` once it has expired.
    private var currentActiveEvent: MoodInput.ActiveEvent {
        guard let eventExpiry, now < eventExpiry else { return .none }
        return detectedEvent
    }

    private var isRateLimitedStatus: Bool {
        if case .rateLimited = status { return true }
        return false
    }

    /// Platform-agnostic snapshot of everything `MoodEngine.pick` needs,
    /// rebuilt live from current store state.
    var moodInput: MoodInput {
        MoodInput(
            sessionFraction: snapshot?.session?.fraction,
            weeklyFraction: snapshot?.weekly?.fraction,
            linked: accountManager.mode != .notLinked && !isNeedsLoginWithoutData,
            offline: lastErrorWasNetwork,
            rateLimited: isRateLimitedStatus,
            claudeActive: claudeActive,
            localHour: Calendar.current.component(.hour, from: now),
            activeEvent: currentActiveEvent
        )
    }

    /// The mood to render: the debug pin if set, else the real engine.
    var currentMood: PetMood {
        debugPinnedMood ?? MoodEngine.pick(input: moodInput)
    }

    /// Weekly usage border-glow level (independent of the pet's mood).
    var weeklyAlert: WeeklyAlert {
        WeeklyAlert.level(snapshot?.weekly?.fraction ?? 0)
    }

    /// Begins the polling loop and the 1s UI clock. Safe to call once; later
    /// calls are ignored.
    func start() {
        guard !started else { return }
        started = true

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.now = Date() }
        }
        if let tickTimer {
            RunLoop.main.add(tickTimer, forMode: .common)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.accountManager.mode != .notLinked else { return }
                await self.refresh(force: true)
            }
        }

        accountModeObserver = NotificationCenter.default.addObserver(
            forName: .usageAccountModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartPolling() }
        }

        startClaudeActiveMonitor()
        restartPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        claudeActiveTask?.cancel()
        claudeActiveTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if let accountModeObserver {
            NotificationCenter.default.removeObserver(accountModeObserver)
        }
        accountModeObserver = nil
        started = false
    }

    /// Fetches a fresh snapshot immediately, outside the normal poll cadence.
    /// No-op while not linked.
    @discardableResult
    func refresh(force: Bool = true) async -> Bool {
        guard accountManager.mode != .notLinked else { return false }
        return await fetchOnce(force: force)
    }

    /// Rebuilds the `UsageClient` for the current account mode and restarts
    /// (or stops) the poll loop. Called on launch and whenever the account
    /// mode changes.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        scheduler = PollScheduler()
        client = Self.makeClient(for: accountManager)

        guard accountManager.mode != .notLinked else {
            snapshot = nil
            lastUpdated = nil
            status = .needsLogin(message: "Link your Claude account to see usage.")
            return
        }

        status = .loading
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let succeeded = await fetchOnce(force: false)
            let delay: TimeInterval
            if succeeded {
                delay = scheduler.nextDelayAfterSuccess()
            } else if case .rateLimited(let until) = status {
                let retryAfter = until?.timeIntervalSinceNow
                delay = scheduler.nextDelayAfterRateLimited(retryAfter: retryAfter)
            } else {
                delay = scheduler.nextDelayAfterFailure()
            }

            let nanoseconds = UInt64(max(delay, 1) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
        }
    }

    @discardableResult
    private func fetchOnce(force: Bool) async -> Bool {
        guard accountManager.mode != .notLinked else {
            status = .needsLogin(message: "Link your Claude account to see usage.")
            return false
        }
        do {
            let result = try await client.fetch(force: force)
            detectResetEvents(previous: snapshot, new: result)
            snapshot = result
            lastUpdated = Date()
            status = .ok
            lastErrorWasNetwork = false
            return true
        } catch UsageClientError.unauthorized {
            status = .needsLogin(message: needsLoginMessage())
            snapshot = nil
            lastErrorWasNetwork = false
            return false
        } catch UsageClientError.rateLimited(let retryAfter) {
            let until = retryAfter.map { Date().addingTimeInterval($0) }
            status = .rateLimited(until: until)
            lastErrorWasNetwork = false
            markStaleIfNeeded()
            return false
        } catch UsageClientError.network(let underlying) where underlying is TokenProviderError {
            // No token at all (e.g. logged out of Claude Code): that's a login
            // problem, not "offline". Drop stale numbers so nothing misleading shows.
            status = .needsLogin(message: needsLoginMessage())
            snapshot = nil
            lastErrorWasNetwork = false
            return false
        } catch UsageClientError.network(let underlying) {
            status = .error(describeError(UsageClientError.network(underlying)))
            lastErrorWasNetwork = true
            markStaleIfNeeded()
            return false
        } catch {
            status = .error(describeError(error))
            lastErrorWasNetwork = false
            markStaleIfNeeded()
            return false
        }
    }

    /// Compares the previous and newly-fetched snapshots for a "just reset"
    /// transition: the window's `resetsAt` jumped forward to a later cycle
    /// (>1h later than the previous value), or its fraction dropped by at
    /// least 30 points. Session resets take priority over weekly resets if
    /// both somehow land in the same fetch. The event then displays for
    /// `eventDuration` seconds (see `currentActiveEvent`).
    private func detectResetEvents(previous: UsageSnapshot?, new: UsageSnapshot) {
        guard let previous else { return }
        if Self.isReset(previous: previous.session, new: new.session) {
            detectedEvent = .sessionReset
            eventExpiry = Date().addingTimeInterval(Self.eventDuration)
        } else if Self.isReset(previous: previous.weekly, new: new.weekly) {
            detectedEvent = .weeklyReset
            eventExpiry = Date().addingTimeInterval(Self.eventDuration)
        }
    }

    private static func isReset(previous: UsageWindow?, new: UsageWindow?) -> Bool {
        guard let previous, let new else { return false }
        if let prevResetsAt = previous.resetsAt, let newResetsAt = new.resetsAt,
           newResetsAt.timeIntervalSince(prevResetsAt) > 3600 {
            return true
        }
        if previous.fraction - new.fraction >= 0.30 {
            return true
        }
        return false
    }

    // MARK: - Claude-active detection

    /// Polls, at most every 10s and off the main thread, whether any
    /// `~/.claude/projects/*/*.jsonl` file was modified in the last 60s —
    /// a cheap proxy for "Claude Code is actively running" that never reads
    /// file contents or tokens.
    private func startClaudeActiveMonitor() {
        claudeActiveTask?.cancel()
        claudeActiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let active = Self.checkClaudeActive()
                guard let self else { return }
                await MainActor.run { self.claudeActive = active }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// Runs entirely off the main actor. Only looks two directory levels
    /// deep under `~/.claude/projects` (project dir, then its `.jsonl`
    /// files) and only reads modification dates.
    nonisolated private static func checkClaudeActive() -> Bool {
        let fileManager = FileManager.default
        let configDir: URL
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDir = URL(fileURLWithPath: dir)
        } else {
            configDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        let projectsDir = configDir.appendingPathComponent("projects")

        guard let level1 = try? fileManager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let cutoff = Date().addingTimeInterval(-60)

        func isRecentJSONL(_ url: URL) -> Bool {
            guard url.pathExtension == "jsonl" else { return false }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate else { return false }
            return mtime > cutoff
        }

        for entry in level1 {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                guard let level2 = try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                if level2.contains(where: isRecentJSONL) {
                    return true
                }
            } else if isRecentJSONL(entry) {
                return true
            }
        }
        return false
    }

    /// Linked in Settings but no usable token (logged out / expired) and nothing to show.
    var isNeedsLoginWithoutData: Bool {
        if case .needsLogin = status, snapshot == nil { return true }
        return false
    }

    private func needsLoginMessage() -> String {
        switch accountManager.mode {
        case .notLinked:
            return "Link your Claude account to see usage."
        case .claudeCode:
            return "Not signed in to Claude Code. Run `claude` and /login, then tap Use Claude Code login."
        case .manualToken:
            return "Saved token is invalid or expired. Paste a new one in Settings."
        }
    }

    /// When a fetch fails but we already have a snapshot to show, prefer
    /// surfacing "stale" (keeping the old numbers visible) over blotting
    /// out the UI with a bare error, as long as nothing more specific
    /// (rate limited / needs login) already applies.
    private func markStaleIfNeeded() {
        guard snapshot != nil, let lastUpdated else { return }
        switch status {
        case .rateLimited, .needsLogin:
            return
        default:
            status = .stale(since: lastUpdated)
        }
    }

    private func describeError(_ error: Error) -> String {
        switch error {
        case UsageClientError.http(let code):
            return "Server error (\(code))"
        case UsageClientError.parse:
            return "Couldn't read usage data"
        case UsageClientError.network:
            return "Network error"
        default:
            return "Something went wrong"
        }
    }
}

#endif
