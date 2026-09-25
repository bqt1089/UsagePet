#if os(macOS)
import SwiftUI
import ClaudeUsageCore

/// Minimized widget: only the current 5h session, in the same 3-row layout
/// as the full card (percent + label, bar, reset countdown), with an expand
/// button on the card itself.
@MainActor
struct MiniPillView: View {
    @Environment(\.widgetScale) private var s
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @Environment(UsageStore.self) private var store
    let onExpand: () -> Void

    private var isStale: Bool {
        guard store.provider == .claude else { return false }
        if case .stale = store.status { return true }
        return false
    }

    private var placeholderText: String? {
        switch store.provider {
        case .claude:
            return store.accountManager.mode == .notLinked ? "Not linked" : nil
        case .antigravity:
            return store.antigravityStatus == .ok ? nil : "AG not open"
        }
    }

    var body: some View {
        Group {
            if let placeholderText {
                HStack {
                    Text(placeholderText)
                        .font(.system(size: 12 * s, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    expandButton
                }
            } else {
                MetricCard(
                    label: "Current",
                    window: store.displayedSnapshot?.session,
                    now: store.now,
                    dimmed: isStale,
                    onExpand: onExpand
                )
            }
        }
        .padding(12 * s)
        .frame(width: 200 * s, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
    }

    private var expandButton: some View {
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

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous).fill(Color.black.opacity(0.7))
        }
        .opacity(backgroundOpacity)
    }
}

#endif
