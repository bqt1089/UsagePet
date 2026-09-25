import Foundation

/// Pure logic for computing the next poll delay based on the outcome of the
/// previous fetch attempt. No I/O, fully testable.
public struct PollScheduler: Sendable {

    public static let successInterval: TimeInterval = 60
    public static let initialBackoff: TimeInterval = 60
    public static let maxBackoff: TimeInterval = 300

    private var currentBackoff: TimeInterval

    public init() {
        currentBackoff = Self.initialBackoff
    }

    /// Call after a successful fetch. Resets backoff and returns the steady
    /// poll interval.
    public mutating func nextDelayAfterSuccess() -> TimeInterval {
        currentBackoff = Self.initialBackoff
        return Self.successInterval
    }

    /// Call after a `UsageClientError.rateLimited` failure.
    public mutating func nextDelayAfterRateLimited(retryAfter: TimeInterval?) -> TimeInterval {
        let backoff = currentBackoff
        currentBackoff = min(currentBackoff * 2, Self.maxBackoff)
        return max(retryAfter ?? 0, backoff)
    }

    /// Call after any other failure (network, http, parse, unauthorized).
    public mutating func nextDelayAfterFailure() -> TimeInterval {
        let backoff = currentBackoff
        currentBackoff = min(currentBackoff * 2, Self.maxBackoff)
        return backoff
    }

    public mutating func reset() {
        currentBackoff = Self.initialBackoff
    }
}
