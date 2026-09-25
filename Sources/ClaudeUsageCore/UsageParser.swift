import Foundation

public enum UsageParseError: Error, Sendable, Equatable {
    case invalidJSON
    case missingWindows
}

public enum UsageParser {

    public static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageParseError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw UsageParseError.invalidJSON
        }

        var session: UsageWindow?
        var weekly: UsageWindow?

        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            // Prefer the account-wide (unscoped) session limit over any
            // model-scoped one that may appear in the same group.
            let isUnscoped: ([String: Any]) -> Bool = { $0["scope"] == nil || $0["scope"] is NSNull }
            let sessionItems = limits.filter { item in
                (item["group"] as? String) == "session" || (item["kind"] as? String) == "session"
            }
            session = (sessionItems.first { ($0["kind"] as? String) == "session" && isUnscoped($0) }
                ?? sessionItems.first(where: isUnscoped)
                ?? sessionItems.first)
                .map { makeWindow(from: $0, fallbackGroup: "session") }

            weekly = limits.first { item in
                (item["kind"] as? String) == "weekly_all"
            }.map { makeWindow(from: $0, fallbackGroup: "weekly") }

            if weekly == nil {
                weekly = limits.first { item in
                    (item["group"] as? String) == "weekly"
                }.map { makeWindow(from: $0, fallbackGroup: "weekly") }
            }
        }

        if session == nil, let fiveHour = root["five_hour"] as? [String: Any] {
            session = makeWindowFromLegacy(fiveHour, kind: "session", group: "session")
        }

        if weekly == nil, let sevenDay = root["seven_day"] as? [String: Any] {
            weekly = makeWindowFromLegacy(sevenDay, kind: "weekly_all", group: "weekly")
        }

        guard session != nil || weekly != nil else {
            throw UsageParseError.missingWindows
        }

        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: now)
    }

    // MARK: - limits[] items

    private static func makeWindow(from item: [String: Any], fallbackGroup: String) -> UsageWindow {
        let kind = (item["kind"] as? String) ?? fallbackGroup
        let group = (item["group"] as? String) ?? fallbackGroup
        let rawPercent = numericValue(item["percent"]) ?? 0
        let fraction = normalize(rawPercent)
        let resetsAt = parseDate(item["resets_at"])
        let severity = Severity(raw: item["severity"] as? String)
        let isActive = (item["is_active"] as? Bool) ?? false
        return UsageWindow(kind: kind, group: group, fraction: fraction, resetsAt: resetsAt, severity: severity, isActive: isActive)
    }

    // MARK: - legacy five_hour / seven_day objects

    private static func makeWindowFromLegacy(_ item: [String: Any], kind: String, group: String) -> UsageWindow {
        let rawUtilization = numericValue(item["utilization"]) ?? 0
        let fraction = normalize(rawUtilization)
        let resetsAt = parseDate(item["resets_at"])
        return UsageWindow(kind: kind, group: group, fraction: fraction, resetsAt: resetsAt, severity: .unknown, isActive: false)
    }

    // MARK: - value normalization

    /// The API always sends 0-100 (`percent`, `utilization`). Never guess
    /// "<= 1 means fraction": a real 1% would then render as 100%.
    private static func normalize(_ value: Double) -> Double {
        min(max(value / 100.0, 0), 1)
    }

    private static func numericValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: - date parsing

    /// Accepts ISO-8601 strings with arbitrary-length fractional seconds
    /// (e.g. ".271287"), plain ISO-8601, or numeric epoch seconds/milliseconds.
    private static func parseDate(_ any: Any?) -> Date? {
        guard let any, !(any is NSNull) else { return nil }

        if let seconds = numericValue(any) {
            // Heuristic: values above ~10^12 are milliseconds.
            if seconds > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: seconds / 1000.0)
            }
            return Date(timeIntervalSince1970: seconds)
        }

        guard let string = any as? String else { return nil }
        return parseISO8601(string)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        // Try with fractional seconds as-is first (covers up to microseconds on
        // some platforms), then fall back to trimming the fractional part to
        // exactly 3 digits (milliseconds), which ISO8601DateFormatter supports.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }

        // Manually normalize fractional seconds to 3 digits and retry.
        if let normalized = normalizeFractionalSeconds(string) {
            if let date = withFraction.date(from: normalized) {
                return date
            }
            if let date = plain.date(from: normalized) {
                return date
            }
        }

        return nil
    }

    /// Finds a "." followed by digits before the timezone designator and
    /// rewrites it to exactly 3 digits (or strips it entirely), so
    /// ISO8601DateFormatter can parse it.
    private static func normalizeFractionalSeconds(_ string: String) -> String? {
        guard let dotIndex = string.firstIndex(of: ".") else { return nil }

        var digitsEnd = string.index(after: dotIndex)
        while digitsEnd < string.endIndex, string[digitsEnd].isNumber {
            digitsEnd = string.index(after: digitsEnd)
        }

        let digits = string[string.index(after: dotIndex)..<digitsEnd]
        guard !digits.isEmpty else { return nil }

        let truncated = String(digits.prefix(3))
        let padded = truncated.padding(toLength: 3, withPad: "0", startingAt: 0)

        var result = string
        result.replaceSubrange(dotIndex..<digitsEnd, with: "." + padded)
        return result
    }
}
