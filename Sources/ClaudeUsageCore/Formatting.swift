import Foundation

public enum Formatting {

    /// Formats the time remaining until `to`, relative to `now`, as a short
    /// human string: "1h 22m", "6d 8h", "45m", "<1m", or "now" when the target
    /// has already passed (or is within a few seconds).
    public static func countdown(to date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)

        if interval <= 0 {
            return "now"
        }

        let totalMinutes = Int(interval / 60)

        if totalMinutes < 1 {
            return "<1m"
        }

        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Formats a 0...1 fraction as a whole-number percent string, e.g. "30%".
    public static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}
