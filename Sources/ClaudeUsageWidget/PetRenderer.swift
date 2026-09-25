#if os(macOS)
import SwiftUI
import ClaudeUsageCore

/// LCD device palette shared by the pixel-pet card and mini strip.
enum LCD {
    static let bezel = Color(red: 0x0f / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0)
    static let bezelStroke = Color(red: 0x2c / 255.0, green: 0x31 / 255.0, blue: 0x3c / 255.0)
    static let screen = Color(red: 0x1d / 255.0, green: 0x24 / 255.0, blue: 0x19 / 255.0)
    static let ink = Color(red: 0xe9 / 255.0, green: 0xf5 / 255.0, blue: 0xdc / 255.0)
    static let inkDim = Color(red: 0xb6 / 255.0, green: 0xc7 / 255.0, blue: 0xa6 / 255.0)
    static let inkFaint = Color(red: 0x8f / 255.0, green: 0xa3 / 255.0, blue: 0x80 / 255.0)
    static let accent = Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    static let barOff = Color(red: 0x2f / 255.0, green: 0x3a / 255.0, blue: 0x2a / 255.0)
    static let dark = Color(red: 0x10 / 255.0, green: 0x14 / 255.0, blue: 0x0e / 255.0)
}

/// Mood colors and animation/eye/mouth/fx metadata, ported 1:1 from the
/// approved HTML mockup's `MOODS` table. `tired`/`ghost`/`hibernate` are
/// intentionally omitted — they're not used by this app's priority rules.
struct MoodStyle {
    var eyes: String
    var mouth: String
    var anim: String
    var fx: [String]
    var color: Color
    var texts: [String]
}

enum PetPalette {
    static let green = Color(red: 0x7E / 255.0, green: 0xD9 / 255.0, blue: 0x57 / 255.0)
    static let lime = Color(red: 0xb5 / 255.0, green: 0xe3 / 255.0, blue: 0x6b / 255.0)
    static let yellow = Color(red: 0xF5 / 255.0, green: 0xC5 / 255.0, blue: 0x42 / 255.0)
    static let orange = Color(red: 0xF2 / 255.0, green: 0x70 / 255.0, blue: 0x4A / 255.0)
    static let red = Color(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0)
    static let grey = Color(red: 0x8a / 255.0, green: 0xa3 / 255.0, blue: 0x7a / 255.0)
    static let blue = Color(red: 0x7c / 255.0, green: 0xc4 / 255.0, blue: 0xff / 255.0)
    static let purple = Color(red: 0xb9 / 255.0, green: 0x9c / 255.0, blue: 0xff / 255.0)
}

enum MoodStyles {
    static let table: [PetMood: MoodStyle] = [
        .ecstatic: MoodStyle(eyes: "sparkle", mouth: "grin", anim: "jump", fx: ["hearts"], color: PetPalette.green, texts: ["Yay!!", "Full power!"]),
        .happy: MoodStyle(eyes: "open", mouth: "smile", anim: "bob", fx: ["blush"], color: PetPalette.green, texts: ["Musing…", "Vibing…"]),
        .chill: MoodStyle(eyes: "half", mouth: "whistle", anim: "sway", fx: ["notes"], color: PetPalette.lime, texts: ["Humming…", "Chillin…"]),
        .focused: MoodStyle(eyes: "focus", mouth: "flat", anim: "bob", fx: [], color: PetPalette.yellow, texts: ["Focusing…", "On it…"]),
        .worried: MoodStyle(eyes: "worried", mouth: "wobble", anim: "bob", fx: ["sweat"], color: PetPalette.orange, texts: ["Uh oh…", "Sweating…"]),
        .stressed: MoodStyle(eyes: "wide", mouth: "teeth", anim: "jitter", fx: ["sweat", "sweat2"], color: PetPalette.orange, texts: ["Hurry!!", "So close…"]),
        .panic: MoodStyle(eyes: "wide", mouth: "scream", anim: "shake", fx: ["alert", "sweat", "flash"], color: PetPalette.red, texts: ["PANIC!!", "AAAA!!"]),
        .sleeping: MoodStyle(eyes: "closed", mouth: "none", anim: "breathe", fx: ["zzz", "bubble"], color: PetPalette.grey, texts: ["Sleeping", "Zzz…"]),
        .celebrate: MoodStyle(eyes: "happy", mouth: "grin", anim: "jump", fx: ["confetti"], color: PetPalette.green, texts: ["RESET!", "Refilled!"]),
        .typing: MoodStyle(eyes: "down", mouth: "tongue", anim: "type", fx: ["laptop"], color: PetPalette.blue, texts: ["Typing…", "Working…"]),
        .confused: MoodStyle(eyes: "odd", mouth: "squiggle", anim: "tilt", fx: ["question"], color: PetPalette.purple, texts: ["Huh?", "Retry soon…"]),
        .dizzy: MoodStyle(eyes: "x", mouth: "wobble", anim: "wobble", fx: ["stars"], color: PetPalette.purple, texts: ["Offline…", "Where am I?"]),
        .lonely: MoodStyle(eyes: "sad", mouth: "frown", anim: "breathe", fx: ["tear"], color: PetPalette.grey, texts: ["Link me?", "Anyone?"]),
        .sleepy: MoodStyle(eyes: "sleepy", mouth: "small", anim: "nod", fx: ["moon"], color: PetPalette.lime, texts: ["Nodding…", "Bedtime?"]),
        .love: MoodStyle(eyes: "heart", mouth: "smile", anim: "bob", fx: ["hearts", "blush"], color: PetPalette.green, texts: ["Thank you!", "New week!"]),
        // `vacation` has no body style — it's drawn as a scene instead.
        .vacation: MoodStyle(eyes: "open", mouth: "smile", anim: "bob", fx: [], color: PetPalette.green, texts: ["Out of office", "Back soon"]),
    ]
}

/// 12x10 body sprite mask, ported verbatim from the mockup's `BODY` array.
private let bodyRows: [String] = [
    "...XXXXXX...",
    ".XXXXXXXXXX.",
    "XXXXXXXXXXXX",
    "XXXXXXXXXXXX",
    "XXXXXXXXXXXX",
    "XXXXXXXXXXXX",
    "XXXXXXXXXXXX",
    ".XXXXXXXXXX.",
    "..XXXXXXXX..",
    "..X.X..X.X..",
]

/// Idle behavior (blink / look) seeded per-instance so multiple pets on
/// screen don't blink in lockstep.
private struct IdleState {
    var blink: Bool
    var look: CGFloat
}

private func idle(t: Double, seed: Int) -> IdleState {
    let ms = t
    let blinkPhase = Int((ms + Double(seed) * 997).rounded(.down) / 110) % 34
    let blink = blinkPhase == 0
    let lookPhase = Int((ms + Double(seed) * 1733).rounded(.down) / 2400) % 5
    let look: CGFloat = lookPhase == 1 ? -1 : (lookPhase == 3 ? 1 : 0)
    return IdleState(blink: blink, look: look)
}

/// Geometry of a just-drawn pet body, so `drawFx` can anchor effects to it.
struct PetGeometry {
    var centerX: CGFloat
    var top: CGFloat
    var width: CGFloat
    var height: CGFloat
    var pixel: CGFloat
}

/// Draws the pixel pet (body + eyes + mouth + fx) or, for `.vacation`, the
/// vacation diorama scene. `time` is milliseconds (matches the mockup's
/// `performance.now()`-based math 1:1); `reduceMotion` collapses animation
/// amplitude to near-zero, matching `prefers-reduced-motion`.
struct PetRenderer {

    let reduceMotion: Bool

    private var R: Double { reduceMotion ? 0 : 1 }

    /// Draws the full pet (or vacation scene) with origin `origin` (top-left
    /// of its 12x10 sprite box) at pixel size `pixel`. Returns nil for a
    /// scene mood consumers that need geometry only for the pet path.
    @discardableResult
    func draw(
        in context: inout GraphicsContext,
        mood: PetMood,
        origin: CGPoint,
        pixel: CGFloat,
        time: Double,
        seed: Int,
        font: (CGFloat, Bool) -> Font
    ) -> PetGeometry? {
        if mood == .vacation {
            drawVacation(in: &context, centerX: origin.x, baseY: origin.y, pixel: pixel, time: time, font: font)
            return nil
        }

        guard let style = MoodStyles.table[mood] else { return nil }
        let id = idle(t: time, seed: seed)
        let P = pixel
        let W = 12 * P
        let H = 10 * P

        var dx: CGFloat = 0, dy: CGFloat = 0, rot: Double = 0, squash: CGFloat = 1

        switch style.anim {
        case "bob":
            dy = CGFloat((sin(time / 320) * 2).rounded()) * CGFloat(R)
        case "jump":
            let p = (time.truncatingRemainder(dividingBy: 700)) / 700
            dy = -CGFloat((abs(sin(p * .pi)) * Double(P) * 3).rounded()) * CGFloat(R)
            squash = (p < 0.1 || p > 0.9) ? 1.08 : 1
        case "sway":
            dx = CGFloat((sin(time / 600) * 2).rounded()) * CGFloat(R)
            rot = sin(time / 600) * 0.06 * R
        case "jitter":
            dx = CGFloat((sin(time / 35)).rounded()) * CGFloat(R)
            dy = CGFloat((cos(time / 45)).rounded()) * CGFloat(R)
        case "shake":
            dx = CGFloat((sin(time / 28) * Double(P) * 0.6).rounded()) * CGFloat(R)
        case "breathe":
            squash = 1 + CGFloat(sin(time / 900) * 0.03 * R)
        case "type":
            dy = CGFloat(Int(time / 120) % 2) * CGFloat(R)
        case "tilt":
            rot = (-0.14 + sin(time / 900) * 0.05) * R
        case "wobble":
            rot = sin(time / 260) * 0.12 * R
            dx = CGFloat((sin(time / 260) * 2).rounded()) * CGFloat(R)
        case "nod":
            let p = time.truncatingRemainder(dividingBy: 3200) / 3200
            let raised = p > 0.7 && p < 0.85
            dy = raised ? P : 0
            rot = raised ? 0.08 : 0
        default:
            break
        }

        let centerX = origin.x + W / 2 + dx
        let top = origin.y + dy

        context.drawLayer { layer in
            layer.translateBy(x: centerX, y: origin.y + H + dy)
            layer.rotate(by: .radians(rot))
            layer.scaleBy(x: 1, y: squash)
            layer.translateBy(x: -W / 2, y: -H)

            let flashOn = style.fx.contains("flash") && (Int(time / 180) % 2 == 1) && reduceMotion == false
            let bodyColor: Color = flashOn ? Color(red: 1, green: 0.54, blue: 0.55) : style.color

            for (r, row) in bodyRows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "X" {
                    let rect = CGRect(x: CGFloat(c) * P, y: CGFloat(r) * P, width: P, height: P)
                    layer.fill(Path(rect), with: .color(bodyColor))
                }
            }
            // top highlight
            layer.fill(Path(CGRect(x: 3 * P, y: 1 * P, width: 2 * P, height: P)), with: .color(.white.opacity(0.25)))

            func px(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ color: Color = LCD.dark) {
                let rect = CGRect(x: cx * P, y: cy * P, width: w * P, height: h * P)
                layer.fill(Path(rect), with: .color(color))
            }

            let L = id.look
            let eyePositions: [(CGFloat, CGFloat)] = [(3, 3), (8, 3)]
            let blinkable: Set<String> = ["closed", "happy", "x", "heart", "sparkle", "sleepy"]
            let blink = id.blink && !blinkable.contains(style.eyes)

            for (i, pos) in eyePositions.enumerated() {
                let ex = pos.0, ey = pos.1
                if blink {
                    px(ex, ey + 1, 2, 1)
                    continue
                }
                switch style.eyes {
                case "open":
                    px(ex + L * 0.5, ey, 2, 2)
                    layer.fill(Path(CGRect(x: (ex + L * 0.5) * P, y: ey * P, width: P / 2, height: P / 2)), with: .color(.white))
                case "half":
                    px(ex, ey + 1, 2, 1)
                    px(ex + (L > 0 ? 1 : 0), ey + 1.5, 1, 0.5)
                case "focus":
                    px(ex, ey, 2, 2)
                    px(ex, ey - 1, 2, 0.5)
                    layer.fill(Path(CGRect(x: (ex + 1) * P, y: ey * P, width: P / 2, height: P / 2)), with: .color(.white))
                case "worried":
                    px(ex, ey, 2, 2)
                    px(i == 1 ? ex : ex + 1, ey - 1, 1, 0.5)
                    px(i == 1 ? ex + 1 : ex, ey - 1.5, 1, 0.5)
                case "wide":
                    px(ex - 0.5, ey - 0.5, 3, 3, .white)
                    px(ex + 0.25 + L * 0.5, ey + 0.25, 1.5, 1.5)
                case "closed":
                    px(ex, ey + 1, 2, 0.5)
                case "happy":
                    px(ex, ey + 1, 0.5, 0.5)
                    px(ex + 0.5, ey + 0.5, 1, 0.5)
                    px(ex + 1.5, ey + 1, 0.5, 0.5)
                case "sparkle":
                    let s = Int(time / 200) % 2
                    px(ex + 0.5, ey - 0.5, 1, 3, .white)
                    px(ex - 0.5, ey + 0.5, 3, 1, .white)
                    if s == 1 { px(ex + 0.5, ey + 0.5, 1, 1, PetPalette.yellow) }
                case "down":
                    px(ex, ey + 1, 2, 1)
                case "odd":
                    if i == 1 { px(ex, ey, 2, 2) } else { px(ex + 0.5, ey + 0.5, 1, 1) }
                case "x":
                    px(ex, ey, 0.6, 0.6)
                    px(ex + 1.4, ey, 0.6, 0.6)
                    px(ex + 0.7, ey + 0.7, 0.6, 0.6)
                    px(ex, ey + 1.4, 0.6, 0.6)
                    px(ex + 1.4, ey + 1.4, 0.6, 0.6)
                case "sad":
                    px(ex, ey + 0.5, 2, 1.5)
                    px(i == 1 ? ex : ex + 1, ey - 0.5, 1, 0.5)
                    layer.fill(Path(CGRect(x: ex * P, y: (ey + 0.5) * P, width: P / 2, height: P / 2)), with: .color(.white))
                case "sleepy":
                    px(ex, ey + 1.2, 2, 0.5)
                    px(ex + 0.5, ey + 0.8, 1, 0.4, Color.black.opacity(0.6))
                case "heart":
                    let beat = 1 + Double(Int(time / 300) % 2) * 0.2 * R
                    let hx = (ex + 1) * P, hy = (ey + 1) * P
                    let s = P * 0.55 * CGFloat(beat)
                    layer.fill(heartPath(centerX: hx, centerY: hy, size: s), with: .color(Color(red: 1, green: 0.365, blue: 0.56)))
                default:
                    break
                }
            }

            // mouth
            let mo = (Int(time / 140) % 2 == 1) && reduceMotion == false
            switch style.mouth {
            case "smile":
                px(4, 6, 0.5, 0.5); px(4.5, 6.5, 3, 0.5); px(7.5, 6, 0.5, 0.5)
            case "grin":
                px(4, 6, 4, 1.5); px(4.5, 6.9, 3, 0.6, Color(red: 1, green: 0.48, blue: 0.525))
            case "whistle":
                px(5.5, 6, 1, 1)
                layer.fill(Path(CGRect(x: 5.75 * P, y: 6.25 * P, width: P / 2, height: P / 2)), with: .color(style.color))
            case "flat":
                px(4.5, 6.3, 3, 0.5)
            case "wobble":
                px(4, 6.5, 1, 0.5); px(5, 6, 1, 0.5); px(6, 6.5, 1, 0.5); px(7, 6, 1, 0.5)
            case "teeth":
                px(4, 6, 4, 1.2); px(4.3, 6.2, 3.4, 0.5, .white)
            case "scream":
                px(4.5, 5.5, 3, mo ? 2.5 : 2); px(5, 6.5, 2, 0.8, Color(red: 1, green: 0.48, blue: 0.525))
            case "none":
                break
            case "tongue":
                px(4.5, 6, 3, 0.5)
                if mo { px(6, 6.5, 1, 0.8, Color(red: 1, green: 0.48, blue: 0.525)) }
            case "frown":
                px(4.5, 6.5, 3, 0.5); px(4, 7, 0.5, 0.5); px(7.5, 7, 0.5, 0.5)
            case "squiggle":
                px(4, 6.3, 1, 0.5); px(5, 6.7, 1, 0.5); px(6, 6.3, 1, 0.5); px(7, 6.7, 0.8, 0.5)
            case "small":
                px(5.5, 6.5, 1, 0.5)
            default:
                break
            }

            if style.fx.contains("blush") {
                let blushColor = Color(red: 1, green: 0.43, blue: 0.55).opacity(0.55)
                layer.fill(Path(CGRect(x: 1.5 * P, y: 5 * P, width: 1.5 * P, height: P * 0.7)), with: .color(blushColor))
                layer.fill(Path(CGRect(x: 9 * P, y: 5 * P, width: 1.5 * P, height: P * 0.7)), with: .color(blushColor))
            }
        }

        return PetGeometry(centerX: centerX, top: top, width: W, height: H, pixel: P)
    }

    /// Draws mood-specific effects anchored to a pet's geometry (hearts,
    /// notes, zzz, sweat, alert, etc). Call right after `draw`.
    func drawFx(in context: inout GraphicsContext, mood: PetMood, geometry: PetGeometry, time: Double, font: (CGFloat, Bool) -> Font) {
        guard let style = MoodStyles.table[mood] else { return }
        let cx = geometry.centerX, top = geometry.top, W = geometry.width, H = geometry.height, P = geometry.pixel
        func T(_ s: Double) -> Double { (time / s).truncatingRemainder(dividingBy: 1) }
        func pxl(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color, alpha: Double = 1) {
            context.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)), with: .color(color.opacity(alpha)))
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool, color: Color, alpha: Double = 1) {
            context.draw(Text(s).font(font(size, bold)).foregroundColor(color.opacity(alpha)), at: CGPoint(x: x, y: y), anchor: .topLeading)
        }

        if style.fx.contains("sweat") {
            let d = T(900) * Double(P) * 4
            pxl(cx + W / 2 - P, top + P * 2 + CGFloat(d), P * 0.6, P, Color(red: 0.56, green: 0.83, blue: 1), alpha: 1 - T(900))
        }
        if style.fx.contains("sweat2") {
            let d = T(700) * Double(P) * 4
            pxl(cx - W / 2 + P * 0.4, top + P * 2.5 + CGFloat(d), P * 0.6, P, Color(red: 0.56, green: 0.83, blue: 1), alpha: 1 - T(700))
        }
        if style.fx.contains("hearts") {
            for i in 0..<3 {
                let p = T(1800 + Double(i) * 300) + Double(i) / 3
                let q = p.truncatingRemainder(dividingBy: 1)
                let hx = cx - W / 2 + CGFloat(i) * W / 2 + CGFloat(sin(q * 6) * 4)
                let hy = top - CGFloat(q) * P * 6
                context.fill(heartPath(centerX: hx, centerY: hy, size: P * 0.9), with: .color(Color(red: 1, green: 0.365, blue: 0.56).opacity(1 - q)))
            }
        }
        if style.fx.contains("notes") {
            for i in 0..<2 {
                let q = (T(2200) + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                text(i == 1 ? "♫" : "♪", cx + W / 2 + CGFloat(q) * P * 3, top + P * 2 - CGFloat(q) * P * 6, size: P * 2.2, bold: true, color: LCD.ink, alpha: 1 - q)
            }
        }
        if style.fx.contains("zzz") {
            for i in 0..<3 {
                let q = (T(2400) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                text("z", cx + W / 2 - P + CGFloat(q) * P * 4 + CGFloat(i * 2), top - CGFloat(q) * P * 6, size: P * 2, bold: true, color: LCD.ink, alpha: 1 - q)
            }
        }
        if style.fx.contains("bubble") {
            let s = CGFloat((sin(time / 900) + 1) / 2) * P * 1.4 + P * 0.6
            let rect = CGRect(x: cx + P * 1.5 - s, y: top + H * 0.72 - s, width: s * 2, height: s * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Color(red: 0.75, green: 0.91, blue: 1)), lineWidth: 1.5)
        }
        if style.fx.contains("alert") {
            let on = (Int(time / 200) % 2 == 1) || reduceMotion
            if on {
                text("!", cx + W / 2, top + P, size: P * 3, bold: true, color: Color(red: 1, green: 0.875, blue: 0.365))
                text("!", cx - W / 2 - P * 2, top + P * 2, size: P * 3, bold: true, color: Color(red: 1, green: 0.875, blue: 0.365))
            }
        }
        if style.fx.contains("question") {
            let b = CGFloat(sin(time / 300) * 2 * R)
            text("?", cx + W / 2, top + b, size: P * 3, bold: true, color: LCD.ink)
        }
        if style.fx.contains("stars") {
            for i in 0..<3 {
                let a = time / 500 * R + Double(i) * 2.1
                let sx = cx + CGFloat(cos(a)) * W * 0.55
                let sy = top - P * 1.5 + CGFloat(sin(a)) * P * 1.2
                text("*", sx - P / 2, sy, size: P * 1.8, bold: true, color: Color(red: 1, green: 0.875, blue: 0.365))
            }
        }
        if style.fx.contains("tear") {
            let q = T(1600)
            pxl(cx - W / 2 + P * 3.2, top + P * 5 + CGFloat(q) * P * 4, P * 0.5, P * 0.8, Color(red: 0.56, green: 0.83, blue: 1), alpha: 1 - q)
        }
        if style.fx.contains("moon") {
            let moonRect = CGRect(x: cx + W / 2 + P * 2 - P * 1.4, y: top - P - P * 1.4, width: P * 2.8, height: P * 2.8)
            context.fill(Path(ellipseIn: moonRect), with: .color(Color(red: 1, green: 0.886, blue: 0.478)))
            let craterRect = CGRect(x: cx + W / 2 + P * 2.7 - P * 1.2, y: top - P * 1.4 - P * 1.2, width: P * 2.4, height: P * 2.4)
            context.fill(Path(ellipseIn: craterRect), with: .color(LCD.screen))
        }
        if style.fx.contains("laptop") {
            let y = top + H + P * 0.2
            pxl(cx - P * 4, y - P * 2, P * 8, P * 2, Color(red: 0.24, green: 0.275, blue: 0.335))
            pxl(cx - P * 5, y, P * 10, P * 0.8, Color(red: 0.353, green: 0.397, blue: 0.467))
            if (Int(time / 120) % 2 == 1) && !reduceMotion {
                pxl(cx - P * 2, y - P * 1.4, P * 1.2, P * 0.4, PetPalette.blue)
            }
        }
        if style.fx.contains("confetti") {
            let cols: [Color] = [
                Color(red: 1, green: 0.875, blue: 0.365),
                Color(red: 1, green: 0.365, blue: 0.56),
                PetPalette.blue,
                PetPalette.green,
                LCD.accent
            ]
            for i in 0..<16 {
                let q = (T(1600) + Double(i) / 16).truncatingRemainder(dividingBy: 1)
                let a = Double(i) * 2.4
                let x = cx + CGFloat(cos(a)) * CGFloat(q) * W * 0.9
                let y = top - P * 2 + CGFloat(sin(a)) * CGFloat(q) * H * 0.5 + CGFloat(q * q) * P * 8
                pxl(x, y, P * 0.6, P * 0.6, cols[i % 5])
            }
        }
    }

    /// Draws the vacation diorama (sun, sea, palm tree, deck chair, pet with
    /// shades, drink) in place of the pet, ported from the mockup's
    /// `drawScene('vacation', ...)`.
    func drawVacation(in context: inout GraphicsContext, centerX cx: CGFloat, baseY: CGFloat, pixel P: CGFloat, time t: Double, font: (CGFloat, Bool) -> Font) {
        func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
            context.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: max(0, w.rounded()), height: max(0, h.rounded()))), with: .color(color))
        }
        // sun
        let sunRadius = P * 2.2 + CGFloat(sin(t / 700) * Double(P) * 0.3 * R)
        let sunRect = CGRect(x: cx + P * 9 - sunRadius, y: baseY - P * 11 - sunRadius, width: sunRadius * 2, height: sunRadius * 2)
        context.fill(Path(ellipseIn: sunRect), with: .color(Color(red: 1, green: 0.827, blue: 0.361)))
        // sea ripples
        for i in 0..<3 {
            let off = ((t / 60 * R) + Double(i) * 14).truncatingRemainder(dividingBy: 28)
            px(cx - P * 13 + CGFloat(off) * P * 0.4, baseY - P * 1.5 + CGFloat(i) * P * 0.6, P * 4, P * 0.4, Color(red: 0.373, green: 0.706, blue: 0.902))
        }
        px(cx - P * 14, baseY, P * 28, P * 1.2, Color(red: 0.910, green: 0.812, blue: 0.541))
        // palm trunk
        px(cx - P * 9, baseY - P * 9, P * 1.2, P * 9, Color(red: 0.541, green: 0.353, blue: 0.2))
        let sway = CGFloat(sin(t / 800) * Double(P) * 0.6 * R)
        for (dx, dy) in [(-4.0, -1.0), (3.0, -1.0), (-3.0, -2.5), (2.5, -2.5)] {
            px(cx - P * 9 + CGFloat(dx) * P + sway, baseY - P * 10 + CGFloat(dy) * P, P * 3.5, P * 0.9, Color(red: 0.31, green: 0.682, blue: 0.31))
        }
        // deck chair + pet
        px(cx - P * 3, baseY - P * 2.5, P * 9, P * 0.8, LCD.accent)
        px(cx + P * 5, baseY - P * 5, P * 0.8, P * 3, LCD.accent)
        px(cx - P * 2, baseY - P * 4.2, P * 7, P * 1.8, PetPalette.green)
        px(cx + P * 3.5, baseY - P * 6, P * 2.4, P * 2.2, PetPalette.green)
        px(cx + P * 3.7, baseY - P * 5.3, P * 2.2, P * 0.6, LCD.dark) // sunglasses
        // drink
        let bob = CGFloat(sin(t / 500) * Double(P) * 0.2 * R)
        px(cx + P * 7, baseY - P * 3 + bob, P * 1.2, P * 1.6, PetPalette.yellow)
        px(cx + P * 7.6, baseY - P * 4.2 + bob, P * 0.3, P * 1.3, Color(red: 1, green: 0.365, blue: 0.56))
    }
}

/// Small heart-shape path, mirroring the mockup's `heart()` helper.
private func heartPath(centerX X: CGFloat, centerY Y: CGFloat, size s: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: X, y: Y + s * 1.1))
    path.addArc(center: CGPoint(x: X - s * 0.5, y: Y), radius: s * 0.55, startAngle: .radians(.pi * 0.8), endAngle: .radians(.pi * 2.05), clockwise: false)
    path.addArc(center: CGPoint(x: X + s * 0.5, y: Y), radius: s * 0.55, startAngle: .radians(.pi * 0.95), endAngle: .radians(.pi * 2.2), clockwise: false)
    path.closeSubpath()
    return path
}

#endif
