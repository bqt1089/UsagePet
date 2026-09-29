import Foundation

/// What the menu bar item shows next to the icon.
public enum MenuBarStyle: String, CaseIterable, Sendable {
    case iconOnly
    case session
    case sessionAndWeekly
}

public enum MenuBarFormatter {

    /// Placeholder shown when there is no number to display yet.
    public static let placeholder = "–"

    /// Session (5h) percent at or above which the menu bar shows a warning icon.
    public static let sessionWarningPercent = 90.0
    /// Weekly percent at or above which the menu bar shows a warning icon.
    public static let weeklyWarningPercent = 95.0

    /// Text shown beside the menu bar icon. Percents are 0...100 (values are
    /// clamped and rounded like the widget does). `.iconOnly` returns "".
    public static func label(session: Double?, weekly: Double?, style: MenuBarStyle) -> String {
        switch style {
        case .iconOnly:
            return ""
        case .session:
            return format(session)
        case .sessionAndWeekly:
            return "\(format(session)) · \(format(weekly))"
        }
    }

    /// True when usage is close enough to the limit to swap in a warning icon.
    public static func showsWarning(session: Double?, weekly: Double?) -> Bool {
        if let session, session.isFinite, session >= sessionWarningPercent { return true }
        if let weekly, weekly.isFinite, weekly >= weeklyWarningPercent { return true }
        return false
    }

    private static func format(_ percent: Double?) -> String {
        guard let percent, percent.isFinite else { return placeholder }
        let clamped = min(max(percent, 0), 100)
        return "\(Int(clamped.rounded()))%"
    }
}
