import Foundation

/// Remembers a server-imposed `Retry-After` window across client rebuilds
/// (wake, watchdog, Refresh Now, network change) and, when backed by
/// `UserDefaults`, across app relaunches. While the window is open no
/// request is sent: poking the endpoint during a 429 only keeps it closed.
public final class RateLimitGate: @unchecked Sendable {

    /// The app-wide gate, persisted so a relaunch doesn't retry early.
    public static let shared = RateLimitGate(defaults: .standard)

    /// Used when the server sends 429 without a usable `Retry-After`.
    public static let fallbackWindow: TimeInterval = 60

    private static let defaultsKey = "usageRateLimitedUntil"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var until: Date?

    /// `defaults == nil` keeps the window in memory only.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.until = defaults?.object(forKey: Self.defaultsKey) as? Date
    }

    /// Seconds left in the current window, or nil when requests may go out.
    public func remaining(now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let until, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    public func block(for seconds: TimeInterval, now: Date = Date()) {
        set(now.addingTimeInterval(max(seconds, 0)))
    }

    public func clear() {
        set(nil)
    }

    private func set(_ date: Date?) {
        lock.lock()
        until = date
        lock.unlock()
        if let date {
            defaults?.set(date, forKey: Self.defaultsKey)
        } else {
            defaults?.removeObject(forKey: Self.defaultsKey)
        }
    }
}
