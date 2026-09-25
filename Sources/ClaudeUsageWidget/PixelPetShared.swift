#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// `time` here is milliseconds since a stable reference point, matching the
/// units `PetRenderer`/the mockup use throughout (so animation math can be
/// ported 1:1).
enum PixelTime {
    static func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate * 1000
    }
}

/// Convenience for drawing pixel-font text with `PixelFont`, matching the
/// mockup's Silkscreen usage.
func pixelText(_ s: String, size: CGFloat, bold: Bool = false, color: Color) -> Text {
    Text(s).font(PixelFont.font(size: size, bold: bold)).foregroundColor(color)
}

/// Animated glow drawn around the widget's rim for Weekly usage between
/// 60% and 99% (at/over 100% the pet is replaced by the vacation scene
/// instead, so no glow is drawn). Ported from the mockup's `drawBorder`.
@MainActor
struct WeeklyBorderGlow: View {
    let level: WeeklyAlert
    let cornerRadius: CGFloat
    let time: Double
    let reduceMotion: Bool

    private var color: Color? {
        switch level {
        case .none: return nil
        case .yellow: return UsageColor.yellow
        case .orange: return UsageColor.orange
        case .red: return UsageColor.red
        }
    }

    /// Pulse period in milliseconds, matching the mockup's `L.speed`.
    private var speedMs: Double {
        switch level {
        case .yellow: return 1400
        case .orange: return 600
        case .red: return 260
        case .none: return 1
        }
    }

    private var lineWidth: CGFloat {
        switch level {
        case .none: return 0
        case .yellow: return 2
        case .orange: return 3
        case .red: return 4
        }
    }

    var body: some View {
        if let color {
            let pulse = reduceMotion ? 1.0 : (sin(time / speedMs) + 1) / 2
            let dashPhase = reduceMotion ? 0 : -(time / (speedMs / 60)).truncatingRemainder(dividingBy: 1018)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color, lineWidth: lineWidth)
                    .opacity(0.45 + pulse * 0.55)
                    .shadow(color: color.opacity(0.9), radius: 6 + pulse * 14)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color(red: 1, green: 0.965, blue: 0.878),
                        style: StrokeStyle(lineWidth: lineWidth, dash: [18, 1000], dashPhase: dashPhase)
                    )
            }
            .allowsHitTesting(false)
        }
    }
}

/// A single 24-segment pixel usage bar with a big percent, small caps label,
/// and reset countdown line — the SwiftUI equivalent of the mockup's
/// `pixBar`.
@MainActor
struct PixelBarRow: View {
    @Environment(\.widgetScale) private var s
    let label: String
    let fraction: Double
    let resetText: String

    private var color: Color { UsageColor.forFraction(fraction, severity: .unknown) }
    private var filledSegments: Int {
        Int((fraction.clamped01() * 24).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            HStack(alignment: .firstTextBaseline) {
                pixelText(Formatting.percent(fraction), size: 17 * s, bold: true, color: LCD.ink)
                Spacer()
                pixelText(label, size: 9 * s, color: LCD.inkDim)
            }
            HStack(spacing: 1 * s) {
                ForEach(0..<24, id: \.self) { i in
                    Rectangle()
                        .fill(i < filledSegments ? color : LCD.barOff)
                        .frame(height: 7 * s)
                }
            }
            pixelText(resetText, size: 8 * s, color: LCD.inkFaint)
        }
    }
}

private extension Double {
    func clamped01() -> Double { Swift.min(Swift.max(self, 0), 1) }
}

/// Tiny pixel-style battery glyph showing the 5h session fraction, standing
/// in for the mockup's hand-drawn battery icon in the header.
@MainActor
/// Weekly battery: how much of the weekly limit is left. Five cells (20% each)
/// act as milestones; color and blinking follow the same thresholds as the
/// weekly rim glow. Empty = weekly limit used up. A bolt shows right after a
/// weekly reset ("recharged").
struct BatteryIcon: View {
    @Environment(\.widgetScale) private var s
    /// Weekly used fraction (0...1), nil when unknown.
    let weekly: Double?
    let time: Double
    var charging: Bool = false
    var showsLabel: Bool = true
    var compact: Bool = false

    private static let cells = 5

    private var used: Double { (weekly ?? 0).clamped01() }
    private var remaining: Double { 1 - used }
    private var isEmpty: Bool { weekly != nil && used >= 1 }
    private var litCells: Int {
        guard weekly != nil, !isEmpty else { return 0 }
        return max(1, Int((remaining * Double(Self.cells)).rounded(.up)))
    }
    private var color: Color {
        guard weekly != nil else { return LCD.inkFaint }
        switch used {
        case ..<0.6: return UsageColor.green
        case ..<0.8: return UsageColor.yellow
        case ..<0.95: return UsageColor.orange
        default: return UsageColor.red
        }
    }
    /// Blink rate grows as the battery drains (ms per half-cycle); nil = steady.
    private var blinkPeriod: Double? {
        guard weekly != nil else { return nil }
        if isEmpty { return 350 }
        if used >= 0.95 { return 250 }
        if used >= 0.8 { return 600 }
        return nil
    }
    private var blinkOn: Bool {
        guard let p = blinkPeriod else { return true }
        return Int(time / p) % 2 == 0
    }

    var body: some View {
        let k: CGFloat = compact ? 0.8 : 1
        let w = 26 * s * k, h = 12 * s * k, pad = 2 * s * k, gap = 1 * s * k
        HStack(spacing: 4 * s * k) {
            HStack(spacing: 1 * s * k) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2 * s * k)
                        .strokeBorder(isEmpty ? (blinkOn ? UsageColor.red : UsageColor.red.opacity(0.3)) : LCD.ink, lineWidth: 1.5 * s * k)
                    HStack(spacing: gap) {
                        ForEach(0..<Self.cells, id: \.self) { i in
                            let lit = i < litCells
                            // The last lit cell blinks when low.
                            let isEdge = lit && i == litCells - 1 && blinkPeriod != nil
                            Rectangle()
                                .fill(lit ? (isEdge && !blinkOn ? color.opacity(0.25) : color) : LCD.barOff)
                        }
                    }
                    .padding(pad)
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9 * s * k, weight: .black))
                            .foregroundStyle(LCD.ink)
                            .shadow(color: .black.opacity(0.6), radius: 0, x: 0.5, y: 0.5)
                    } else if isEmpty {
                        pixelText("!", size: 9 * s * k, bold: true, color: blinkOn ? UsageColor.red : .clear)
                    }
                }
                .frame(width: w, height: h)
                Rectangle()
                    .fill(isEmpty ? UsageColor.red : LCD.ink)
                    .frame(width: 2 * s * k, height: 5 * s * k)
            }
            if showsLabel {
                pixelText(weekly == nil ? "--" : "\(Int((remaining * 100).rounded()))%", size: 8 * s * k, bold: true, color: color)
                    .monospacedDigit()
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let weekly else { return "Weekly limit: unknown" }
        if weekly >= 1 { return "Weekly limit used up" }
        return "Weekly limit: \(Int((remaining * 100).rounded()))% left (\(Int((weekly * 100).rounded()))% used)"
    }
}

/// Faint horizontal scanlines over the LCD screen, matching the mockup's
/// `rgba(0,0,0,.12)` stripes every 3px.
@MainActor
struct ScanlinesView: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.12)))
                    y += 3
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Rotates through a mood's status texts every 1.8s and prepends a blinking
/// "*"/"+" marker, matching the mockup's bottom status line.
func moodStatusLine(mood: PetMood, time: Double) -> String {
    let texts = MoodStyles.table[mood]?.texts ?? ["…"]
    let index = Int(time / 1800) % texts.count
    let marker = (Int(time / 400) % 2 == 0) ? "*" : "+"
    return "\(marker) \(texts[index])"
}

#endif
