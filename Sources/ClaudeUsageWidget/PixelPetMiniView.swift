#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// Minimized "Pixel Pet" strip: a small pet (or vacation scene) + Current
/// percent + a segmented bar + reset countdown, with the same expand
/// button and Weekly border glow as the full card.
@MainActor
struct PixelPetMiniView: View {
    @Environment(\.widgetScale) private var s
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @Environment(UsageStore.self) private var store
    let onExpand: () -> Void

    private var isStale: Bool {
        guard store.provider == .claude else { return false }
        if case .stale = store.status { return true }
        return false
    }
    /// Whether there's real usage data to show for the active provider.
    private var hasData: Bool {
        switch store.provider {
        case .claude: return store.accountManager.mode != .notLinked
        case .antigravity: return store.antigravityStatus == .ok
        }
    }
    private var placeholderLabel: String {
        store.provider == .claude ? "NOT LINKED" : "AG NOT OPEN"
    }

    var body: some View {
        let mood = store.currentMood
        let weeklyAlert = store.weeklyAlert
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let highMotion = mood == .celebrate || mood == .panic || PetHoverModel.shared.isHovering
        let interval: Double = reduceMotion ? (1.0 / 6.0) : (highMotion ? (1.0 / 24.0) : (1.0 / 12.0))

        TimelineView(.animation(minimumInterval: interval, paused: false)) { timeline in
            let t = PixelTime.milliseconds(timeline.date)

            ZStack {
                RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                    .fill(LCD.bezel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                            .strokeBorder(LCD.bezelStroke, lineWidth: 1.5)
                    )
                    .opacity(backgroundOpacity)

                HStack(spacing: 8 * s) {
                    petThumbnail(mood: mood, time: t, reduceMotion: reduceMotion)
                .reportPetFrame()
                        .frame(width: 40 * s, height: 40 * s)

                    if hasData {
                        VStack(alignment: .leading, spacing: 3 * s) {
                            HStack(alignment: .firstTextBaseline) {
                                pixelText(Formatting.percent(store.displayedSnapshot?.session?.fraction ?? 0), size: 14 * s, bold: true, color: LCD.ink)
                                Spacer()
                            }
                            HStack(spacing: 1 * s) {
                                ForEach(0..<24, id: \.self) { i in
                                    Rectangle()
                                        .fill(i < filledSegments ? UsageColor.forFraction(store.displayedSnapshot?.session?.fraction ?? 0, severity: .unknown) : LCD.barOff)
                                        .frame(height: 5 * s)
                                }
                            }
                            pixelText(resetText, size: 7 * s, color: LCD.inkFaint)
                        }
                        .opacity(isStale ? 0.5 : 1.0)
                    } else {
                        pixelText(placeholderLabel, size: 10 * s, color: LCD.inkDim)
                        Spacer()
                    }

                    expandButton
                }
                .padding(.horizontal, 10 * s)
                .padding(.vertical, 8 * s)
            }
            .overlay(alignment: .topTrailing) {
                if hasData {
                    BatteryIcon(weekly: store.displayedSnapshot?.weekly?.fraction, time: t, charging: mood == .love, showsLabel: false, compact: true)
                        .padding(.top, 5 * s)
                        .padding(.trailing, 9 * s)
                }
            }
            .overlay(WeeklyBorderGlow(level: weeklyAlert, cornerRadius: 14 * s, time: t, reduceMotion: reduceMotion))
        }
        .frame(width: 200 * s, height: 56 * s)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func petThumbnail(mood: PetMood, time: Double, reduceMotion: Bool) -> some View {
        let hover = PetHoverModel.shared.active(at: time)
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(LCD.screen.opacity(backgroundOpacity)))

            let shadowRect = CGRect(x: size.width / 2 - 12, y: size.height - 8, width: 24, height: 3)
            context.fill(Path(ellipseIn: shadowRect), with: .color(.black.opacity(0.25)))

            let renderer = PetRenderer(reduceMotion: reduceMotion)
            if mood == .vacation {
                renderer.drawVacation(
                    in: &context,
                    centerX: size.width / 2,
                    baseY: size.height - 6,
                    pixel: 1.6,
                    time: time,
                    font: PixelFont.font
                )
            } else {
                let pixel: CGFloat = 2.5
                let origin = CGPoint(x: size.width / 2 - 6 * pixel, y: 2)
                let reactStyle = hover.flatMap { PetHover.style(base: mood, reaction: $0.0) }
                var petCtx = context
                if let (r, e) = hover {
                    PetHover.applyMotion(r, base: mood, elapsed: e, center: CGPoint(x: origin.x + 6 * pixel, y: origin.y + 5 * pixel), pixel: pixel, to: &petCtx, reduceMotion: reduceMotion)
                }
                if let geometry = renderer.draw(
                    in: &petCtx,
                    mood: mood,
                    origin: origin,
                    pixel: pixel,
                    time: time,
                    seed: 1,
                    font: PixelFont.font,
                    styleOverride: reactStyle
                ) {
                    renderer.drawFx(in: &petCtx, mood: mood, geometry: geometry, time: time, font: PixelFont.font, styleOverride: reactStyle)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8 * s, weight: .bold))
                .foregroundStyle(LCD.ink.opacity(0.75))
                .frame(width: 18 * s, height: 18 * s)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help("Expand")
    }

    private var filledSegments: Int {
        let fraction = store.displayedSnapshot?.session?.fraction ?? 0
        return Int((min(max(fraction, 0), 1) * 24).rounded())
    }

    private var resetText: String {
        guard let window = store.displayedSnapshot?.session, let resetsAt = window.resetsAt else { return "resets in --" }
        if window.fraction >= 1.0 {
            return "limited · \(Formatting.countdown(to: resetsAt, now: store.now))"
        }
        return "resets in \(Formatting.countdown(to: resetsAt, now: store.now))"
    }
}

#endif
