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

    /// Exactly one usage source is shown at a time. Persisted in
    /// `UserDefaults` under `"provider"` (also the key `@AppStorage` binds to
    /// in Settings/the menu), defaulting to `.claude`.
    enum Provider: String, Hashable {
        case claude
        case antigravity
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
    private var antigravityPollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var accountModeObserver: NSObjectProtocol?
    private var providerDefaultsObserver: NSObjectProtocol?
    private var started = false

    // MARK: - Provider selection

    private static let providerKey = "provider"
    /// `provider`/`antigravityGroupPreference` live in UserDefaults (shared
    /// with @AppStorage), which Observation can't see. Views read this
    /// stored counter through the getters so they re-render on change.
    private var defaultsRevision = 0
    private static let antigravityGroupKey = "antigravityGroup"

    /// Backed by `@AppStorage("provider")` in Settings/the menu/the header
    /// button. Exactly one provider is ever polled or displayed at a time.
    var provider: Provider {
        get {
            _ = defaultsRevision
            return UserDefaults.standard.string(forKey: Self.providerKey).flatMap(Provider.init(rawValue:)) ?? .claude
        }
        set {
            guard newValue != provider else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.providerKey)
            // `syncProviderPolling()` also runs from the UserDefaults
            // change notification, but calling it here too keeps the
            // switch instantaneous instead of waiting a runloop turn.
            syncProviderPolling()
        }
    }

    /// Flips between Claude Code and Antigravity. Used by the header
    /// label's tap target and the menu bar's Provider picker.
    func toggleProvider() {
        provider = (provider == .claude) ? .antigravity : .claude
    }

    /// Backed by `@AppStorage("antigravityGroup")` in Settings; "auto" (the
    /// tightest group), "gemini", or "3p".
    var antigravityGroupPreference: String {
        get { _ = defaultsRevision; return UserDefaults.standard.string(forKey: Self.antigravityGroupKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: Self.antigravityGroupKey); defaultsRevision += 1 }
    }

    init(accountManager: AccountManager) {
        self.accountManager = accountManager
        self.client = Self.makeClient(for: accountManager)
    }

    private static func makeClient(for accountManager: AccountManager) -> UsageClient {
        guard let provider = accountManager.makeTokenProvider() else {
            // No mode selected yet; this client is never actually polled
            // against (see `restartClaudePolling`), but give it something inert.
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
    /// rebuilt live from current store state, for whichever provider is
    /// currently active.
    var moodInput: MoodInput {
        switch provider {
        case .antigravity:
            // A much simpler linked/offline model than Claude Code's —
            // either the app is running and answering, or it isn't. No
            // fallback to Claude: not-open/errored just reads as "lonely".
            return MoodInput(
                sessionFraction: displayedSnapshot?.session?.fraction,
                weeklyFraction: displayedSnapshot?.weekly?.fraction,
                linked: antigravityStatus == .ok,
                offline: false,
                rateLimited: false,
                claudeActive: false,
                localHour: Calendar.current.component(.hour, from: now),
                activeEvent: currentActiveEvent
            )
        case .claude:
            return MoodInput(
                sessionFraction: displayedSnapshot?.session?.fraction,
                weeklyFraction: displayedSnapshot?.weekly?.fraction,
                linked: accountManager.mode != .notLinked && !isNeedsLoginWithoutData,
                offline: lastErrorWasNetwork,
                rateLimited: isRateLimitedStatus,
                claudeActive: claudeActive,
                localHour: Calendar.current.component(.hour, from: now),
                activeEvent: currentActiveEvent
            )
        }
    }

    /// The mood to render: the debug pin if set, else the real engine.
    var currentMood: PetMood {
        debugPinnedMood ?? MoodEngine.pick(input: moodInput)
    }

    /// Weekly usage border-glow level (independent of the pet's mood),
    /// following whichever provider is currently active.
    var weeklyAlert: WeeklyAlert {
        WeeklyAlert.level(displayedSnapshot?.weekly?.fraction ?? 0)
    }

    // MARK: - Antigravity provider

    enum AntigravityStatus: Equatable {
        case notRunning
        case ok
        case error(String)
    }

    private(set) var antigravityGroups: [ProviderGroupUsage] = []
    private(set) var antigravityStatus: AntigravityStatus = .notRunning
    private(set) var antigravityLastUpdated: Date?

    private let antigravityClient = AntigravityClient()
    private var antigravityScheduler = PollScheduler()

    /// Maps an Antigravity group id to the `UsageSource` case
    /// `UsageSourceSelector.tightest` understands, so "auto" can reuse that
    /// existing helper instead of duplicating its comparison logic.
    private static func usageSource(forGroupId id: String) -> UsageSource? {
        switch id {
        case "gemini": return .antigravityGemini
        case "3p": return .antigravityOther
        default: return nil
        }
    }

    private static func groupId(for source: UsageSource) -> String? {
        switch source {
        case .antigravityGemini: return "gemini"
        case .antigravityOther: return "3p"
        case .claude: return nil
        }
    }

    /// The Antigravity group id actually shown right now: the user's
    /// explicit pick from `antigravityGroupPreference` when it currently has
    /// data, else "auto" — the group with the highest `max(session, weekly)`
    /// used fraction — else whatever group came back first.
    var activeAntigravityGroupId: String? {
        let preference = antigravityGroupPreference
        if preference != "auto", antigravityGroups.contains(where: { $0.id == preference }) {
            return preference
        }
        let candidates: [(UsageSource, UsageSnapshot)] = antigravityGroups.compactMap { group in
            guard let source = Self.usageSource(forGroupId: group.id) else { return nil }
            return (source, group.snapshot)
        }
        if let tightest = UsageSourceSelector.tightest(candidates), let id = Self.groupId(for: tightest) {
            return id
        }
        return antigravityGroups.first?.id
    }

    /// Short label for the active Antigravity group ("Gemini" / "Claude &
    /// GPT"), or nil while no group data has loaded yet.
    var antigravityGroupShortLabel: String? {
        switch activeAntigravityGroupId {
        case "gemini": return "Gemini"
        case "3p": return "Claude & GPT"
        default: return nil
        }
    }

    /// Compact uppercase suffix for the pixel status/footer line ("GEM" /
    /// "3P"), nil while unknown.
    var antigravityGroupPixelSuffix: String? {
        switch activeAntigravityGroupId {
        case "gemini": return "GEM"
        case "3p": return "3P"
        default: return nil
        }
    }

    // MARK: - Displayed snapshot

    /// The snapshot every usage-rendering view should read from: the
    /// Claude snapshot, or the active Antigravity group's snapshot,
    /// depending on `provider`.
    var displayedSnapshot: UsageSnapshot? {
        switch provider {
        case .claude:
            return snapshot
        case .antigravity:
            guard let id = activeAntigravityGroupId else { return nil }
            return antigravityGroups.first { $0.id == id }?.snapshot
        }
    }

    /// Header label for the active provider: "CLAUDE" / "ANTIGRAVITY"
    /// (pixel theme, uppercase) or "Claude" / "Antigravity" (classic
    /// theme). The Antigravity model-group suffix is shown separately, in
    /// the status/footer line, so the 240pt-wide header never overflows.
    func providerLabel(pixel: Bool) -> String {
        switch provider {
        case .claude:
            return pixel ? "CLAUDE" : "Claude"
        case .antigravity:
            return pixel ? "ANTIGRAVITY" : "Antigravity"
        }
    }

    /// Tooltip for the header's provider-switch button.
    var providerSwitchHelp: String {
        provider == .claude ? "Switch to Antigravity" : "Switch to Claude"
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
                await self.refresh(force: true)
            }
        }

        accountModeObserver = NotificationCenter.default.addObserver(
            forName: .usageAccountModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartClaudePolling() }
        }

        providerDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncProviderPolling() }
        }

        startClaudeActiveMonitor()
        lastProvider = provider
        switch provider {
        case .claude:
            restartClaudePolling()
        case .antigravity:
            startAntigravityPolling()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        antigravityPollTask?.cancel()
        antigravityPollTask = nil
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
        if let providerDefaultsObserver {
            NotificationCenter.default.removeObserver(providerDefaultsObserver)
        }
        providerDefaultsObserver = nil
        started = false
    }

    /// Fetches a fresh snapshot immediately, outside the normal poll
    /// cadence, for whichever provider is currently active.
    @discardableResult
    func refresh(force: Bool = true) async -> Bool {
        switch provider {
        case .claude:
            guard accountManager.mode != .notLinked else { return false }
            return await fetchOnce(force: force)
        case .antigravity:
            return await fetchAntigravityOnce(force: force)
        }
    }

    // MARK: - Provider switching

    private var lastProvider: Provider = .claude

    /// Starts the poll loop for the newly-active provider and stops the
    /// other one, so only one provider ever talks to the network/Keychain
    /// (Claude) or runs `ps`/`lsof`/local requests (Antigravity). Called on
    /// launch and whenever `provider` changes (both directly, via the
    /// setter, and via the `UserDefaults` change notification so a change
    /// made in Settings is picked up too).
    private func syncProviderPolling() {
        defaultsRevision &+= 1
        let current = provider
        guard current != lastProvider else { return }
        lastProvider = current

        // A switch is not a reset: forget whatever snapshot reset-event
        // detection was tracking so the next fetch just re-baselines
        // instead of comparing across providers.
        previousEventKey = nil
        previousEventSnapshot = nil

        pollTask?.cancel()
        pollTask = nil
        antigravityPollTask?.cancel()
        antigravityPollTask = nil

        switch current {
        case .claude:
            antigravityGroups = []
            antigravityStatus = .notRunning
            restartClaudePolling()
        case .antigravity:
            status = .loading
            snapshot = nil
            startAntigravityPolling()
        }

        // Switching providers should feel instant rather than waiting for
        // the new loop's first cadence; the loop above is enough on its
        // own, but a force refresh makes the very first fetch skip any
        // still-warm cache on the client/actor being switched to.
        Task { [weak self] in await self?.refresh(force: true) }
    }

    // MARK: - Antigravity polling

    /// Starts (or restarts) the Antigravity poll loop. Only ever running
    /// while `provider == .antigravity`.
    private func startAntigravityPolling() {
        antigravityPollTask?.cancel()
        antigravityScheduler = PollScheduler()
        antigravityStatus = .notRunning
        antigravityPollTask = Task { [weak self] in
            await self?.antigravityPollLoop()
        }
    }

    private func antigravityPollLoop() async {
        while !Task.isCancelled {
            let succeeded = await fetchAntigravityOnce(force: false)
            let delay = succeeded
                ? antigravityScheduler.nextDelayAfterSuccess()
                : antigravityScheduler.nextDelayAfterFailure()

            let nanoseconds = UInt64(max(delay, 1) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
        }
    }

    @discardableResult
    private func fetchAntigravityOnce(force: Bool) async -> Bool {
        guard provider == .antigravity else { return false }
        do {
            let groups = try await antigravityClient.fetchGroups(force: force)
            antigravityGroups = groups
            antigravityStatus = .ok
            antigravityLastUpdated = Date()
            if let id = activeAntigravityGroupId, let snap = groups.first(where: { $0.id == id })?.snapshot {
                noteSnapshotForEventDetection(key: "antigravity:\(id)", snapshot: snap)
            }
            return true
        } catch AntigravityClientError.notRunning {
            antigravityGroups = []
            antigravityStatus = .notRunning
            return false
        } catch {
            antigravityStatus = .error(describeAntigravityError(error))
            return false
        }
    }

    private func describeAntigravityError(_ error: Error) -> String {
        switch error {
        case AntigravityClientError.protocolChanged:
            return "Antigravity: can't read quota"
        case AntigravityClientError.parse:
            return "Antigravity: can't read quota"
        case AntigravityClientError.network:
            return "Couldn't reach Antigravity"
        default:
            return "Antigravity: can't read quota"
        }
    }

    // MARK: - Claude polling

    /// Rebuilds the `UsageClient` for the current account mode and restarts
    /// (or stops) the Claude poll loop. Only ever running while
    /// `provider == .claude`. Called on launch, whenever the account mode
    /// changes, and whenever `provider` switches back to Claude.
    private func restartClaudePolling() {
        guard provider == .claude else { return }
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
        guard provider == .claude else { return false }
        guard accountManager.mode != .notLinked else {
            status = .needsLogin(message: "Link your Claude account to see usage.")
            return false
        }
        do {
            let result = try await client.fetch(force: force)
            noteSnapshotForEventDetection(key: "claude", snapshot: result)
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

    // MARK: - Reset-event detection

    /// Which (provider, group) the last-noted snapshot belonged to, so a
    /// provider/group switch doesn't get compared against a snapshot from a
    /// different source and misfire a "reset" celebration.
    private var previousEventKey: String?
    private var previousEventSnapshot: UsageSnapshot?

    /// Feeds one freshly-fetched snapshot into reset-event detection.
    /// Snapshots are only compared against the immediately-previous one
    /// fetched under the same `key` (e.g. "claude" or
    /// "antigravity:gemini"); a different key just re-baselines silently.
    private func noteSnapshotForEventDetection(key: String, snapshot: UsageSnapshot) {
        defer {
            previousEventKey = key
            previousEventSnapshot = snapshot
        }
        guard previousEventKey == key, let previous = previousEventSnapshot else { return }
        detectResetEvents(previous: previous, new: snapshot)
    }

    /// Compares the previous and newly-fetched snapshots for a "just reset"
    /// transition: the window's `resetsAt` jumped forward to a later cycle
    /// (>1h later than the previous value), or its fraction dropped by at
    /// least 30 points. Session resets take priority over weekly resets if
    /// both somehow land in the same fetch. The event then displays for
    /// `eventDuration` seconds (see `currentActiveEvent`).
    private func detectResetEvents(previous: UsageSnapshot, new: UsageSnapshot) {
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
