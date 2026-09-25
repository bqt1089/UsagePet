import Foundation

public enum Severity: String, Sendable {
    case normal
    case warning
    case critical
    case unknown

    public init(raw: String?) {
        guard let raw, let value = Severity(rawValue: raw) else {
            self = .unknown
            return
        }
        self = value
    }
}

public struct UsageWindow: Sendable, Equatable {
    public var kind: String
    public var group: String
    public var fraction: Double
    public var resetsAt: Date?
    public var severity: Severity
    public var isActive: Bool

    public init(kind: String, group: String, fraction: Double, resetsAt: Date?, severity: Severity, isActive: Bool) {
        self.kind = kind
        self.group = group
        self.fraction = min(max(fraction, 0), 1)
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var fetchedAt: Date

    public init(session: UsageWindow?, weekly: UsageWindow?, fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}

extension Severity {
    // Equatable/Codable via RawRepresentable already; nothing extra needed.
}

extension UsageWindow: Codable {}
extension UsageSnapshot: Codable {}

extension Severity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Severity(rawValue: raw) ?? .unknown
    }
}

/// Which quota source is currently being displayed. `.claude` is Claude
/// Code's own usage; the `antigravity*` cases mirror the model groups
/// Antigravity's local quota API reports (see `AntigravityQuotaParser`).
public enum UsageSource: String, CaseIterable, Sendable, Equatable {
    case claude
    case antigravityGemini = "ag.gemini"
    case antigravityOther = "ag.3p"
}

/// Picks whichever source is "tightest" — closest to running out — among a
/// set of candidate snapshots, so "Auto" mode can surface the number that
/// most needs the user's attention.
public enum UsageSourceSelector {

    /// Returns the source whose `max(session, weekly)` used-fraction is
    /// highest. Ties keep the earliest candidate in `candidates` (stable by
    /// input order). Returns `nil` for an empty list.
    public static func tightest(_ candidates: [(UsageSource, UsageSnapshot)]) -> UsageSource? {
        var best: (source: UsageSource, value: Double)?
        for (source, snapshot) in candidates {
            let value = max(snapshot.session?.fraction ?? 0, snapshot.weekly?.fraction ?? 0)
            if let currentBest = best {
                if value > currentBest.value {
                    best = (source, value)
                }
            } else {
                best = (source, value)
            }
        }
        return best?.source
    }
}
