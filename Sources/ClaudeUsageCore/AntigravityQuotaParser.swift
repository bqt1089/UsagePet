import Foundation

/// One quota group from Antigravity's `RetrieveUserQuotaSummary` response
/// (e.g. "Gemini Models" or "Claude and GPT models"), normalized into the
/// same `UsageSnapshot` shape the Claude usage UI already renders.
public struct ProviderGroupUsage: Equatable, Sendable {
    /// The bucket-id prefix shared by this group's buckets, e.g. "gemini"
    /// or "3p". Stable across responses; used to key UI state.
    public let id: String
    public let displayName: String
    public let snapshot: UsageSnapshot

    public init(id: String, displayName: String, snapshot: UsageSnapshot) {
        self.id = id
        self.displayName = displayName
        self.snapshot = snapshot
    }
}

public enum AntigravityParseError: Error, Sendable, Equatable {
    case invalidJSON
    case missingGroups
}

/// Parses the (internal, undocumented) JSON body Antigravity's local
/// language server returns from
/// `POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`.
/// Parses loosely with `JSONSerialization` and ignores unknown fields, since
/// this is a reverse-engineered protocol that may change without notice.
public enum AntigravityQuotaParser {

    public static func parse(_ data: Data, now: Date) throws -> [ProviderGroupUsage] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityParseError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw AntigravityParseError.invalidJSON
        }

        // The real payload nests everything under "response"; accept a
        // pre-unwrapped root too, for flexibility/testability.
        let container = (root["response"] as? [String: Any]) ?? root
        guard let groups = container["groups"] as? [[String: Any]], !groups.isEmpty else {
            throw AntigravityParseError.missingGroups
        }

        var results: [ProviderGroupUsage] = []
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]], !buckets.isEmpty else { continue }
            let displayName = (group["displayName"] as? String) ?? "Unknown"

            var sessionWindow: UsageWindow?
            var weeklyWindow: UsageWindow?
            var idPrefix: String?

            for bucket in buckets {
                guard let bucketId = bucket["bucketId"] as? String else { continue }
                if idPrefix == nil {
                    idPrefix = prefix(fromBucketId: bucketId)
                }
                guard let window = window(fromBucketId: bucketId, bucket: bucket) else { continue }
                switch window.kind {
                case "session":
                    sessionWindow = window
                case "weekly_all":
                    weeklyWindow = window
                default:
                    break
                }
            }

            guard let id = idPrefix else { continue }
            let snapshot = UsageSnapshot(session: sessionWindow, weekly: weeklyWindow, fetchedAt: now)
            results.append(ProviderGroupUsage(id: id, displayName: displayName, snapshot: snapshot))
        }

        guard !results.isEmpty else { throw AntigravityParseError.missingGroups }
        return results
    }

    // MARK: - bucket id / window classification

    private static func prefix(fromBucketId bucketId: String) -> String {
        for suffix in ["-weekly", "-5h"] {
            if bucketId.hasSuffix(suffix) {
                return String(bucketId.dropLast(suffix.count))
            }
        }
        return bucketId
    }

    /// Returns `nil` when `remainingFraction` is missing/non-numeric (an
    /// "unknown" bucket — NOT the same as "0 remaining"), or when the
    /// bucket's window can't be classified as 5h/weekly.
    private static func window(fromBucketId bucketId: String, bucket: [String: Any]) -> UsageWindow? {
        guard let remainingFraction = numericValue(bucket["remainingFraction"]) else { return nil }

        let kind: String
        if let windowValue = (bucket["window"] as? String)?.lowercased() {
            switch windowValue {
            case "5h": kind = "session"
            case "weekly": kind = "weekly_all"
            default: return nil
            }
        } else if bucketId.hasSuffix("-5h") {
            kind = "session"
        } else if bucketId.hasSuffix("-weekly") {
            kind = "weekly_all"
        } else {
            return nil
        }

        let group = kind == "session" ? "session" : "weekly"
        let used = 1 - min(max(remainingFraction, 0), 1)
        let resetsAt = parseDate(bucket["resetTime"])
        return UsageWindow(kind: kind, group: group, fraction: used, resetsAt: resetsAt, severity: .unknown, isActive: false)
    }

    private static func numericValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let string = any as? String else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
