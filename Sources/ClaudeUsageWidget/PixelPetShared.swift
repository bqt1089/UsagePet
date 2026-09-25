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
struct BatteryIcon: View {
    @Environment(\.widgetScale) private var s
    let fraction: Double

    var body: some View {
        HStack(spacing: 1 * s) {
            RoundedRectangle(cornerRadius: 1.5 * s)
                .strokeBorder(LCD.ink, lineWidth: 1.5 * s)
                .frame(width: 20 * s, height: 10 * s)
                .overlay(
                    HStack {
                        Rectangle()
                            .fill(LCD.ink)
                            .frame(width: max(1 * s, 16 * s * CGFloat(1 - fraction.clamped01())))
                        Spacer(minLength: 0)
                    }
                    .padding(2 * s)
                )
            Rectangle()
                .fill(LCD.ink)
                .frame(width: 2 * s, height: 4 * s)
        }
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
