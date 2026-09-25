#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// Reports the intrinsic size of its SwiftUI content up to `WidgetPanel` so
/// the panel can resize itself when mini mode toggles.
private struct WidgetSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Top-level content hosted by `WidgetPanel`. Switches between the full card
/// and the mini pill, and wires up the shared double-click / context-menu
/// behavior that applies to both.
@MainActor
struct WidgetRootView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("miniMode") private var miniMode = false
    @AppStorage("widgetScale") private var widgetScale = WidgetScale.default
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @AppStorage("theme") private var theme = WidgetTheme.pixel.rawValue
    @State private var baseSize: CGSize = .zero
    let onResize: (CGSize) -> Void
    let onInvalidateShadow: () -> Void

    private var scale: Double { WidgetScale.clamp(widgetScale) }
    private var isPixelTheme: Bool { theme == WidgetTheme.pixel.rawValue }

    var body: some View {
        Group {
            if miniMode {
                if isPixelTheme {
                    PixelPetMiniView(onExpand: { miniMode = false })
                        .onTapGesture(count: 2) { miniMode = false }
                } else {
                    MiniPillView(onExpand: { miniMode = false })
                        .onTapGesture(count: 2) { miniMode = false }
                }
            } else {
                if isPixelTheme {
                    PixelPetWidgetView(onMinimize: { miniMode = true })
                        .onTapGesture(count: 2) { miniMode = true }
                } else {
                    WidgetView(onMinimize: { miniMode = true })
                        .onTapGesture(count: 2) { miniMode = true }
                }
            }
        }
        .fixedSize()
        .environment(\.widgetScale, CGFloat(scale))
        .onChange(of: widgetScale) { onResize(.zero) }
        .onChange(of: miniMode) { onResize(.zero) }
        .onChange(of: theme) { onResize(.zero) }
        .onChange(of: store.accountManager.mode) { onResize(.zero) }
        .onChange(of: store.displayedSnapshot == nil) { onResize(.zero) }
        .onChange(of: backgroundOpacity) { onInvalidateShadow() }
        .contextMenu {
            Button(miniMode ? "Expand" : "Minimize") {
                miniMode.toggle()
            }
            Button("Refresh") {
                Task { await store.refresh(force: true) }
            }
            Divider()
            Button("Hide") {
                UserDefaults.standard.set(false, forKey: "widgetVisible")
                NotificationCenter.default.post(name: .usageWidgetVisibilityChanged, object: nil)
            }
        }
    }
}

extension WidgetRootView {
    fileprivate func reportSize() { onResize(.zero) }
}

private struct WidgetScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Layout multiplier for fonts, paddings and sizes (Settings > Widget size).
    var widgetScale: CGFloat {
        get { self[WidgetScaleKey.self] }
        set { self[WidgetScaleKey.self] = newValue }
    }
}

/// Allowed widget scale range (1.0 = 240pt wide card).
enum WidgetScale {
    static let min = 0.7
    static let max = 1.6
    static let `default` = 1.0
    static func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, min), max) }
}

/// Opens Terminal running `claude /login`. Returns false if AppleScript failed.
@MainActor
enum ClaudeCodeLogin {
    @discardableResult
    static func openTerminal() -> Bool {
        guard let script = NSAppleScript(source: "tell application \"Terminal\"\n activate\n do script \"claude /login\"\nend tell") else { return false }
        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        return errorDict == nil
    }
}

/// Fraction/severity -> bar color. Bumps up to at least orange/red when the
/// server itself reports warning/critical, even if the raw fraction looks
/// lower than our own thresholds would suggest.
enum UsageColor {
    static let green = Color(red: 0x7E / 255.0, green: 0xD9 / 255.0, blue: 0x57 / 255.0)
    static let yellow = Color(red: 0xF5 / 255.0, green: 0xC5 / 255.0, blue: 0x42 / 255.0)
    static let orange = Color(red: 0xF2 / 255.0, green: 0x70 / 255.0, blue: 0x4A / 255.0)
    static let red = Color(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0)

    static func forFraction(_ fraction: Double, severity: Severity) -> Color {
        var color: Color
        switch fraction {
        case ..<0.6: color = green
        case ..<0.8: color = yellow
        case ..<0.95: color = orange
        default: color = red
        }

        switch severity {
        case .critical:
            if color != red { color = red }
        case .warning:
            if color == green || color == yellow { color = orange }
        default:
            break
        }
        return color
    }
}

/// The full dark usage card.
@MainActor
struct WidgetView: View {
    @Environment(\.widgetScale) private var s
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @Environment(UsageStore.self) private var store
    let onMinimize: () -> Void

    private var isStale: Bool {
        if case .stale = store.status { return true }
        return false
    }

    private var isLinked: Bool {
        store.accountManager.mode != .notLinked
    }

    /// Linked, but no token / token rejected and nothing to show yet.
    private var needsLoginWithoutData: Bool {
        if case .needsLogin = store.status, store.displayedSnapshot == nil { return true }
        return false
    }

    private var isAntigravityUnavailable: Bool {
        store.provider == .antigravity && store.antigravityStatus != .ok
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            header

            switch store.provider {
            case .claude:
                if isLinked && !needsLoginWithoutData {
                    VStack(spacing: 10 * s) {
                        MetricCard(
                            label: "Current",
                            window: store.displayedSnapshot?.session,
                            now: store.now,
                            dimmed: isStale
                        )
                        MetricCard(
                            label: "Weekly",
                            window: store.displayedSnapshot?.weekly,
                            now: store.now,
                            dimmed: isStale
                        )
                    }
                } else {
                    linkAccountSection
                }
            case .antigravity:
                if isAntigravityUnavailable {
                    antigravityUnavailableSection
                } else {
                    VStack(spacing: 10 * s) {
                        MetricCard(
                            label: "Current",
                            window: store.displayedSnapshot?.session,
                            now: store.now,
                            dimmed: false
                        )
                        MetricCard(
                            label: "Weekly",
                            window: store.displayedSnapshot?.weekly,
                            now: store.now,
                            dimmed: false
                        )
                    }
                }
            }

            footer
        }
        .padding(16 * s)
        .frame(width: 240 * s, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16 * s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                .fill(Color.black.opacity(0.7))
        }
        .opacity(backgroundOpacity)
    }

    private var header: some View {
        HStack(spacing: 6 * s) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundStyle(.white)
            Button(action: { store.toggleProvider() }) {
                HStack(spacing: 3 * s) {
                    Text(store.providerLabel(pixel: false))
                        .font(.system(size: 13 * s, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 8 * s, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .help(store.providerSwitchHelp)
            Spacer()
            Button(action: onMinimize) {
                Image(systemName: "minus")
                    .font(.system(size: 9 * s, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18 * s, height: 18 * s)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            Circle()
                .fill(statusColor)
                .frame(width: 8 * s, height: 8 * s)
        }
    }

    private var linkAccountSection: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            Button {
                store.accountManager.useClaudeCodeLogin()
                Task { await store.refresh(force: true) }
            } label: {
                Label("Use Claude Code login", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8 * s)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10 * s) {
                Button("Sign in to Claude Code…") { ClaudeCodeLogin.openTerminal() }
                Button("More options") { requestShowSettings() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10 * s, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))

            Text(isLinked
                 ? "No valid Claude Code login found. Sign in, then tap Use Claude Code login."
                 : "Reads your Claude Code login (read-only). macOS will ask for Keychain access.")
                .font(.system(size: 10 * s))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var antigravityUnavailableSection: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            Text("Antigravity not open")
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundStyle(.white)
            Text("Open the app, then wait a moment.")
                .font(.system(size: 10 * s))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18 * s)
    }

    private func requestShowSettings() {
        NotificationCenter.default.post(name: .usageWidgetShowSettings, object: nil)
    }

    private var statusColor: Color {
        if store.provider == .antigravity {
            switch store.antigravityStatus {
            case .ok: return UsageColor.green
            case .notRunning: return UsageColor.yellow
            case .error: return UsageColor.red
            }
        }
        switch store.status {
        case .ok: return UsageColor.green
        case .loading, .stale: return UsageColor.yellow
        case .rateLimited, .error: return UsageColor.red
        case .needsLogin: return UsageColor.red
        }
    }

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 10 * s))
            .foregroundStyle(.white.opacity(0.55))
    }

    private var footerText: String {
        if store.provider == .antigravity {
            switch store.antigravityStatus {
            case .notRunning:
                return "Open Antigravity"
            case .error(let message):
                return message
            case .ok:
                let group = store.antigravityGroupShortLabel.map { " · \($0)" } ?? ""
                if let lastUpdated = store.antigravityLastUpdated {
                    let seconds = max(0, Int(store.now.timeIntervalSince(lastUpdated)))
                    return "Updated \(seconds)s ago\(group)"
                }
                return "Updated just now\(group)"
            }
        }
        switch store.status {
        case .loading:
            return "Loading…"
        case .ok:
            if let lastUpdated = store.lastUpdated {
                let seconds = max(0, Int(store.now.timeIntervalSince(lastUpdated)))
                return "Updated \(seconds)s ago"
            }
            return "Updated just now"
        case .stale(let since):
            return "Last update \(Formatting.countdown(to: store.now, now: since)) ago"
        case .rateLimited(let until):
            if let until {
                return "Rate limited · retry in \(Formatting.countdown(to: until, now: store.now))"
            }
            return "Rate limited"
        case .needsLogin(let message):
            return message
        case .error(let message):
            return message
        }
    }
}

/// One metric row: big percent, a pill label, a progress bar, and the
/// reset countdown.
@MainActor
struct MetricCard: View {
    @Environment(\.widgetScale) private var s
    let label: String
    let window: UsageWindow?
    let now: Date
    let dimmed: Bool
    var onExpand: (() -> Void)? = nil

    private var fraction: Double { window?.fraction ?? 0 }
    private var severity: Severity { window?.severity ?? .unknown }
    private var color: Color { UsageColor.forFraction(fraction, severity: severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .firstTextBaseline) {
                Text(window != nil ? Formatting.percent(fraction) : "--%")
                    .font(.system(size: 22 * s, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(label)
                    .font(.system(size: 10 * s, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8 * s)
                    .padding(.vertical, 3 * s)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                if let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8 * s, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18 * s, height: 18 * s)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Expand")
                }
            }

            ProgressBar(fraction: fraction, color: color)
                .frame(height: 8 * s)

            Text(resetText)
                .font(.system(size: 10 * s))
                .foregroundStyle(.white.opacity(0.55))
        }
        .opacity(dimmed ? 0.5 : 1.0)
    }

    private var resetText: String {
        guard let window else { return "Resets in --" }
        guard let resetsAt = window.resetsAt else { return "Resets in unknown" }
        return "Resets in \(Formatting.countdown(to: resetsAt, now: now))"
    }
}

@MainActor
private struct ProgressBar: View {
    @Environment(\.widgetScale) private var s
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .clipShape(Capsule())
    }
}

#endif
