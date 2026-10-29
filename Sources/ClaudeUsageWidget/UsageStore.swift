#if os(macOS)
import Foundation
import AppKit
import Observation
import Network
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
        /// Claude Code's token expired while we still have numbers to show:
        /// keep them visible (dimmed) until `claude` runs and renews it.
        case tokenExpired(since: Date?)
        case error(String)
    }

    static let tokenExpiredMessage = "Claude Code login expired. Run `claude` once to renew it; usage refreshes automatically."

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

    private var client: any UsageFetching
    private var scheduler = PollScheduler()
    private var pollTask: Task<Void, Never>?
    private var claudeActiveTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var accountModeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false
    private var reconnectTask: Task<Void, Never>?
    private var appNapActivity: NSObjectProtocol?
    private var started = false

    init(accountManager: AccountManager) {
        self.accountManager = accountManager
        self.client = Self.makeClient(for: accountManager)
    }

    private static func makeClient(for accountManager: AccountManager) -> any UsageFetching {
        guard let fetcher = accountManager.makeUsageFetcher() else {
            // No mode selected yet (or a linked mode with nothing usable);
            // this client is never actually polled against (see
            // `restartPolling`), but give it something inert.
            return UsageClient(tokenProvider: StaticTokenProvider { nil })
        }
        return fetcher
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

        // With the floating widget hidden the app has no visible window, so
        // macOS App Naps it: the poll sleep and the watchdog timer stall
        // until the menu is opened, and the menu bar numbers freeze.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Polling Claude usage for the menu bar"
        )

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date()
                self.watchdog()
            }
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
                // Fresh client + URLSession: connections from before sleep are
                // often dead. Wait a moment: Wi-Fi is rarely back the instant
                // the lid opens, and an early failure costs a 60 s backoff.
                self.scheduleRestart(after: 3)
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
        startNetworkMonitor()
        restartPolling()
    }

    /// Restarts polling as soon as connectivity returns (Wi-Fi reconnect,
    /// network switch, VPN up/down) instead of waiting out the backoff.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkPathChanged(isUp: isUp) }
        }
        monitor.start(queue: DispatchQueue(label: "UsagePet.network-path"))
        pathMonitor = monitor
    }

    private func networkPathChanged(isUp: Bool) {
        guard isUp else {
            networkWasDown = true
            return
        }
        guard networkWasDown || lastErrorWasNetwork else { return }
        networkWasDown = false
        scheduleRestart(after: 2)
    }

    /// Debounced `restartPolling`, so a burst of wake / path events results
    /// in one fresh client instead of several cancelled requests.
    private func scheduleRestart(after delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.accountManager.mode != .notLinked else { return }
            self.restartPolling()
        }
    }

    /// Self-heal: if nothing has succeeded for a long time while linked,
    /// rebuild the client and restart the loop (covers stuck requests, a
    /// dead connection pool, or a loop that stopped for any reason).
    private var lastWatchdogRestart = Date()
    private func watchdog() {
        guard accountManager.mode != .notLinked else { return }
        let reference = lastUpdated ?? lastWatchdogRestart
        guard now.timeIntervalSince(reference) > 8 * 60,
              now.timeIntervalSince(lastWatchdogRestart) > 8 * 60 else { return }
        lastWatchdogRestart = now
        restartPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        claudeActiveTask?.cancel()
        claudeActiveTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if let accountModeObserver {
            NotificationCenter.default.removeObserver(accountModeObserver)
        }
        accountModeObserver = nil
        if let appNapActivity {
            ProcessInfo.processInfo.endActivity(appNapActivity)
        }
        appNapActivity = nil
        started = false
    }

    /// Fetches a fresh snapshot immediately, outside the normal poll cadence.
    /// No-op while not linked.
    @discardableResult
    func refresh(force: Bool = true) async -> Bool {
        guard accountManager.mode != .notLinked else { return false }
        return await fetchOnce(force: force)
    }

    /// True while a user-triggered refresh is in flight (drives "Refreshing…").
    private(set) var isRefreshing = false
    /// When the last user-triggered refresh finished (drives "Updated just now").
    private(set) var lastManualRefreshAt: Date?
    private(set) var lastManualRefreshSucceeded = false

    /// "Refresh Now": fresh client + connection pool, reset backoff, fetch
    /// immediately, then resume the normal 5 min loop from this point. A plain
    /// fetch wasn't enough: while the loop was in a long backoff (or the old
    /// connection pool was dead) nothing visibly changed.
    func refreshNow() async {
        guard accountManager.mode != .notLinked, !isRefreshing else { return }
        isRefreshing = true
        pollTask?.cancel()
        pollTask = nil
        scheduler = PollScheduler()
        client = Self.makeClient(for: accountManager)
        let ok = await fetchOnce(force: true)
        isRefreshing = false
        lastManualRefreshAt = Date()
        lastManualRefreshSucceeded = ok
        let firstDelay = ok ? scheduler.nextDelayAfterSuccess() : scheduler.nextDelayAfterFailure()
        pollTask = Task { [weak self] in
            await self?.pollLoop(initialDelay: firstDelay)
        }
    }

    /// Rebuilds the `UsageClient` for the current account mode and restarts
    /// (or stops) the poll loop. Called on launch and whenever the account
    /// mode changes.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        // Any restart counts for the watchdog, so it never cancels a fresh
        // loop (e.g. the very first fetch at launch, or one right after wake).
        lastWatchdogRestart = Date()
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

    private func pollLoop(initialDelay: TimeInterval = 0) async {
        if initialDelay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000)) } catch { return }
        }
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
        } catch UsageClientError.unauthorized where accountManager.mode == .claudeCode && snapshot != nil {
            // The token worked before, so a 401 now is almost always expiry
            // (a sign-out removes the token and lands in the case below).
            markTokenExpired()
            return false
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
        } catch UsageClientError.network(let underlying) where (underlying as? TokenProviderError) == .keychainTimedOut {
            status = .needsLogin(message: "macOS is waiting for Keychain access. Click Use Claude Code login, then choose Always Allow.")
            lastErrorWasNetwork = false
            markStaleIfNeeded()
            return false
        } catch UsageClientError.network(let underlying) where (underlying as? TokenProviderError) == .expired {
            markTokenExpired()
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
                let accountInfo = AccountManager.readClaudeCodeAccountInfo()
                guard let self else { return }
                await MainActor.run {
                    self.claudeCodeAccountObserved(accountInfo)
                    // Claude Code just ran, so it has likely renewed its token.
                    if active, !self.claudeActive, self.isTokenExpired {
                        self.scheduleRestart(after: 2)
                    }
                    self.claudeActive = active
                }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// `claude /login` with another account (personal <-> org) swaps the
    /// token under us while the mode stays `.claudeCode`. Without this the
    /// old account's numbers stay up until the next 5 min poll, then the
    /// switch looks like a usage reset, and a 401/403 from the new account
    /// is misread as an expired token because a snapshot exists.
    private func claudeCodeAccountObserved(_ info: AccountInfo?) {
        guard accountManager.mode == .claudeCode else { return }
        let previous = accountManager.accountInfo
        guard info != previous else { return }
        accountManager.updateAccountInfo(info)
        guard let identity = info?.identity, let previousIdentity = previous?.identity,
              identity != previousIdentity else { return }

        snapshot = nil
        lastUpdated = nil
        detectedEvent = .none
        eventExpiry = nil
        lastErrorWasNetwork = false
        // A 429 window belongs to the account that earned it.
        RateLimitGate.shared.clear()
        pollTask?.cancel()
        pollTask = nil
        status = .loading
        // Claude Code may write ~/.claude.json a moment before the new
        // token lands in the Keychain; don't fetch with the old one.
        scheduleRestart(after: 3)
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
            if AccountManager.claudeCodeCredentialsLackSubscription() {
                return "Claude Code is signed in without a subscription (API key?). Run Sign in to Claude Code… and choose \"Claude account with subscription\"."
            }
            return "Not signed in to Claude Code. Run `claude` and /login, then tap Use Claude Code login."
        case .manualToken:
            return "Saved token is invalid or expired. Paste a new one in Settings."
        }
    }

    private func markTokenExpired() {
        lastErrorWasNetwork = false
        if snapshot == nil {
            status = .needsLogin(message: Self.tokenExpiredMessage)
        } else {
            status = .tokenExpired(since: lastUpdated)
        }
    }

    var isTokenExpired: Bool {
        if case .tokenExpired = status { return true }
        return false
    }

    /// Why the numbers on screen are old, or nil when they are current (or
    /// there are none). The menu bar keeps showing the last snapshot through
    /// every failure, so without this a dead token looks like flat usage.
    var staleNotice: String? {
        guard snapshot != nil else { return nil }
        switch status {
        case .ok, .loading:
            return nil
        case .tokenExpired:
            return Self.tokenExpiredMessage
        case .rateLimited(let until):
            if let until {
                return "Rate limited · retry in \(Formatting.countdown(to: until, now: now))"
            }
            return "Rate limited"
        case .stale:
            return lastErrorWasNetwork ? "Offline · retrying" : "Couldn't refresh · retrying"
        case .needsLogin(let message), .error(let message):
            return message
        }
    }

    /// "Updated 4d 23h ago" for the last successful fetch.
    var lastUpdatedText: String? {
        guard let lastUpdated else { return nil }
        let seconds = now.timeIntervalSince(lastUpdated)
        if seconds < 60 { return "Updated just now" }
        return "Updated \(Formatting.countdown(to: now, now: lastUpdated)) ago"
    }

    /// When a fetch fails but we already have a snapshot to show, prefer
    /// surfacing "stale" (keeping the old numbers visible) over blotting
    /// out the UI with a bare error, as long as nothing more specific
    /// (rate limited / needs login) already applies.
    private func markStaleIfNeeded() {
        guard snapshot != nil, let lastUpdated else { return }
        switch status {
        case .rateLimited, .needsLogin, .tokenExpired:
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
