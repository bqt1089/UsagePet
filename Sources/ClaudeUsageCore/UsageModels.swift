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
