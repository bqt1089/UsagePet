import Foundation

/// The pixel pet's current expression. `tired` is intentionally not a case
/// here: per product rule, Weekly usage never changes the pet's mood (it is
/// shown only as a border glow around the widget).
public enum PetMood: String, Sendable, Equatable, CaseIterable {
    case ecstatic
    case happy
    case chill
    case focused
    case worried
    case stressed
    case panic
    case sleeping
    case celebrate
    case love
    case typing
    case sleepy
    case confused
    case dizzy
    case lonely
    case vacation
}

/// Everything `MoodEngine.pick` needs to decide the current pet mood. Kept
/// platform-agnostic (no AppKit/SwiftUI) so it is unit-testable on any
/// platform, including Linux CI.
public struct MoodInput: Sendable, Equatable {

    /// A recently-observed reset transition, valid only for a short window
    /// after it's detected (see `UsageStore`'s 3.5s event expiry).
    public enum ActiveEvent: Sendable, Equatable {
        case none
        case sessionReset
        case weeklyReset
    }

    /// 0...1 fraction of the 5h ("Current") window used. `nil` when no
    /// snapshot has loaded yet.
    public var sessionFraction: Double?

    /// 0...1 fraction of the weekly window used. `nil` when no snapshot has
    /// loaded yet.
    public var weeklyFraction: Double?

    /// Whether an account is linked at all (Settings > Account).
    public var linked: Bool

    /// True on a network/connection failure talking to the usage API.
    public var offline: Bool

    /// True while the usage API is actively rate-limiting us.
    public var rateLimited: Bool

    /// True when Claude Code appears to be actively running (see
    /// `UsageStore`'s jsonl-mtime heuristic).
    public var claudeActive: Bool

    /// The user's local wall-clock hour (0...23), used for the "sleepy at
    /// night" rule.
    public var localHour: Int

    /// A just-detected reset transition, if any.
    public var activeEvent: ActiveEvent

    public init(
        sessionFraction: Double? = nil,
        weeklyFraction: Double? = nil,
        linked: Bool = true,
        offline: Bool = false,
        rateLimited: Bool = false,
        claudeActive: Bool = false,
        localHour: Int = 12,
        activeEvent: ActiveEvent = .none
    ) {
        self.sessionFraction = sessionFraction
        self.weeklyFraction = weeklyFraction
        self.linked = linked
        self.offline = offline
        self.rateLimited = rateLimited
        self.claudeActive = claudeActive
        self.localHour = localHour
        self.activeEvent = activeEvent
    }
}

/// Pure decision logic mapping usage state to a `PetMood`, per the approved
/// priority rules:
///
/// 1. (Pinned preview is a UI-layer / debug-only concern, not modeled here.)
/// 2. A just-detected reset event wins: session reset -> `celebrate`,
///    weekly reset -> `love`.
/// 3. Weekly at/over 100% -> `vacation` (replaces the pet entirely).
/// 4. Not linked -> `lonely`; offline -> `dizzy`; rate limited -> `confused`.
/// 5. Otherwise, the pet follows the 5h "Current" fraction only. Weekly
///    below 100% never changes the pet's mood (see `WeeklyAlert`).
public enum MoodEngine {

    public static func pick(input: MoodInput) -> PetMood {
        switch input.activeEvent {
        case .sessionReset:
            return .celebrate
        case .weeklyReset:
            return .love
        case .none:
            break
        }

        if let weekly = input.weeklyFraction, weekly >= 1.0 {
            return .vacation
        }

        if !input.linked {
            return .lonely
        }
        if input.offline {
            return .dizzy
        }
        if input.rateLimited {
            return .confused
        }

        let cur = input.sessionFraction ?? 0

        if cur >= 1.0 { return .sleeping }
        if cur >= 0.95 { return .panic }
        if cur >= 0.90 { return .stressed }
        if cur >= 0.80 { return .worried }
        if input.claudeActive { return .typing }
        let isNight = input.localHour >= 23 || input.localHour < 5
        if isNight && cur < 0.60 { return .sleepy }
        if cur >= 0.60 { return .focused }
        if cur >= 0.40 { return .chill }
        if cur >= 0.10 { return .happy }
        return .ecstatic
    }
}

/// Weekly-usage border-glow level. Weekly usage never changes the pet's
/// mood directly (see `MoodEngine`); instead it's rendered as an animated
/// glow around the widget's rim.
public enum WeeklyAlert: String, Sendable, Equatable {
    case none
    case yellow
    case orange
    case red

    /// `fraction` is the weekly 0...1 usage fraction. At/over 100% the pet
    /// is already replaced by the `vacation` scene, so no border is drawn.
    public static func level(_ fraction: Double) -> WeeklyAlert {
        if fraction >= 1.0 { return .none }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.80 { return .orange }
        if fraction >= 0.60 { return .yellow }
        return .none
    }
}
