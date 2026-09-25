#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// Full "Pixel Pet" themed usage card: an LCD-device look with the pet (or
/// vacation scene) in a little screen, segmented Current/Weekly bars (or,
/// while not linked, the same link-account actions as the classic theme),
/// and a rotating status line. Ported from the approved HTML mockup.
@MainActor
struct PixelPetWidgetView: View {
    @Environment(\.widgetScale) private var s
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @Environment(UsageStore.self) private var store
    let onMinimize: () -> Void

    private var isStale: Bool {
        if case .stale = store.status { return true }
        return false
    }
    private var isLinked: Bool { store.accountManager.mode != .notLinked }
    private var needsLoginWithoutData: Bool {
        if case .needsLogin = store.status, store.snapshot == nil { return true }
        return false
    }

    var body: some View {
        let mood = store.currentMood
        let weeklyAlert = store.weeklyAlert
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let highMotion = mood == .celebrate || mood == .panic
        let interval: Double = reduceMotion ? (1.0 / 6.0) : (highMotion ? (1.0 / 24.0) : (1.0 / 12.0))

        TimelineView(.animation(minimumInterval: interval, paused: false)) { timeline in
            let t = PixelTime.milliseconds(timeline.date)

            ZStack {
                RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                    .fill(LCD.bezel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                            .strokeBorder(LCD.bezelStroke, lineWidth: 2)
                    )
                    .opacity(backgroundOpacity)

                content(mood: mood, time: t, reduceMotion: reduceMotion)
                    .padding(12 * s)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(LCD.screen)
                            ScanlinesView()
                        }
                        .opacity(backgroundOpacity)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12 * s, style: .continuous))
                    .padding(10 * s)
            }
            .overlay(WeeklyBorderGlow(level: weeklyAlert, cornerRadius: 22 * s, time: t, reduceMotion: reduceMotion))
        }
        .frame(width: 240 * s, height: 280 * s)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(mood: PetMood, time: Double, reduceMotion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            header

            petArea(mood: mood, time: time, reduceMotion: reduceMotion)
                .frame(height: 92 * s)

            if isLinked && !needsLoginWithoutData {
                VStack(alignment: .leading, spacing: 10 * s) {
                    PixelBarRow(
                        label: "CURRENT",
                        fraction: store.snapshot?.session?.fraction ?? 0,
                        resetText: currentResetText
                    )
                    PixelBarRow(
                        label: "WEEKLY",
                        fraction: store.snapshot?.weekly?.fraction ?? 0,
                        resetText: weeklyResetText
                    )
                }
                .opacity(isStale ? 0.5 : 1.0)
            } else {
                linkAccountSection
            }

            pixelText(moodStatusLine(mood: mood, time: time), size: 11 * s, color: LCD.accent)
                .lineLimit(1)
        }
    }

    private var header: some View {
        HStack(spacing: 6 * s) {
            pixelText("USAGE", size: 13 * s, bold: true, color: LCD.ink)
            Spacer()
            BatteryIcon(fraction: store.snapshot?.session?.fraction ?? 0)
            Button(action: onMinimize) {
                Image(systemName: "minus")
                    .font(.system(size: 9 * s, weight: .bold))
                    .foregroundStyle(LCD.ink.opacity(0.8))
                    .frame(width: 16 * s, height: 16 * s)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            Circle()
                .fill(statusColor)
                .frame(width: 7 * s, height: 7 * s)
        }
    }

    @ViewBuilder
    private func petArea(mood: PetMood, time: Double, reduceMotion: Bool) -> some View {
        let hover = PetHoverModel.shared.active(at: time)
        Canvas { context, size in
            let shadowRect = CGRect(x: size.width / 2 - 34, y: 74, width: 68, height: 8)
            context.fill(Path(ellipseIn: shadowRect), with: .color(.black.opacity(0.25)))

            let renderer = PetRenderer(reduceMotion: reduceMotion)
            if mood == .vacation {
                renderer.drawVacation(
                    in: &context,
                    centerX: size.width / 2,
                    baseY: 76,
                    pixel: 4,
                    time: time,
                    font: PixelFont.font
                )
                if let (r, e) = hover {
                    PetHover.drawBubble(PetHover.bubbleText(base: mood, reaction: r), elapsed: e, anchor: CGPoint(x: size.width / 2 + 8, y: 30), pixel: 4, in: &context, font: PixelFont.font)
                }
            } else {
                let pixel: CGFloat = 5
                let origin = CGPoint(x: size.width / 2 - 6 * pixel, y: 6)
                let shown = hover.map { PetHover.shownMood(base: mood, reaction: $0.0) } ?? mood
                var petCtx = context
                if let (r, e) = hover {
                    PetHover.applyMotion(r, base: mood, elapsed: e, center: CGPoint(x: origin.x + 6 * pixel, y: origin.y + 5 * pixel), pixel: pixel, to: &petCtx, reduceMotion: reduceMotion)
                }
                if let geometry = renderer.draw(
                    in: &petCtx,
                    mood: shown,
                    origin: origin,
                    pixel: pixel,
                    time: time,
                    seed: 1,
                    font: PixelFont.font
                ) {
                    renderer.drawFx(in: &petCtx, mood: shown, geometry: geometry, time: time, font: PixelFont.font)
                }
                if let (r, e) = hover {
                    PetHover.drawBubble(PetHover.bubbleText(base: mood, reaction: r), elapsed: e, anchor: CGPoint(x: origin.x + 10 * pixel, y: origin.y + 1 * pixel), pixel: pixel, in: &context, font: PixelFont.font)
                }
            }
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
                    .foregroundStyle(LCD.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6 * s)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10 * s) {
                Button("Sign in to Claude Code…") { ClaudeCodeLogin.openTerminal() }
                Button("More options") { requestShowSettings() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10 * s, weight: .medium))
            .foregroundStyle(LCD.inkDim)
        }
    }

    private func requestShowSettings() {
        NotificationCenter.default.post(name: .usageWidgetShowSettings, object: nil)
    }

    private var statusColor: Color {
        switch store.status {
        case .ok: return UsageColor.green
        case .loading, .stale: return UsageColor.yellow
        case .rateLimited, .error: return UsageColor.red
        case .needsLogin: return UsageColor.red
        }
    }

    private var currentResetText: String {
        guard let window = store.snapshot?.session else { return "resets in --" }
        if window.fraction >= 1.0 {
            guard let resetsAt = window.resetsAt else { return "limited · --" }
            return "limited · \(Formatting.countdown(to: resetsAt, now: store.now))"
        }
        guard let resetsAt = window.resetsAt else { return "resets in --" }
        return "resets in \(Formatting.countdown(to: resetsAt, now: store.now))"
    }

    private var weeklyResetText: String {
        guard let window = store.snapshot?.weekly else { return "resets in --" }
        guard let resetsAt = window.resetsAt else { return "resets in --" }
        if window.fraction >= 1.0 {
            return "back in \(Formatting.countdown(to: resetsAt, now: store.now))"
        }
        return "resets in \(Formatting.countdown(to: resetsAt, now: store.now))"
    }
}

#endif
