#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// Interactions the pet reacts to with the mouse.
///
/// - greeting (hearts / wave / wiggle / spin): pointer rests on the pet normally
/// - cute: pointer held still on the pet for ~1.2 s
/// - tickle: small fast back-and-forth jiggles on the pet
/// - dizzy: rubbing the pet too much (lots of movement / direction changes)
/// - knocked: pointer sweeps into the pet very fast; it falls over, then gets up
/// - laugh: clicking (poking) the pet
enum HoverReaction: Equatable {
    case hearts, wave, wiggle, spin
    case cute, tickle, laugh, dizzy
    case knocked(dir: CGFloat)

    static let greetings: [HoverReaction] = [.hearts, .wave, .wiggle, .spin]

    /// Loop length (continuous) or total length (one-shot), ms.
    var duration: Double {
        switch self {
        case .laugh: return 1600
        case .dizzy: return 2800
        case .knocked: return 1900
        default: return 2400
        }
    }

    /// One-shot reactions play fully even if the pointer leaves.
    var isOneShot: Bool {
        switch self {
        case .laugh, .dizzy, .knocked: return true
        default: return false
        }
    }

    var bubble: String {
        switch self {
        case .hearts: return "<3 hehe"
        case .wave: return "Hi!"
        case .wiggle: return "Hehe~"
        case .spin: return "Wheee!"
        case .cute: return "Purr~ <3"
        case .tickle: return "Hihi! Stop!"
        case .laugh: return "Hahaha!"
        case .dizzy: return "@_@ dizzy…"
        case .knocked: return "Oof!"
        }
    }

    /// Face/fx used while reacting (body color comes from the current mood).
    func style(color: Color) -> MoodStyle {
        switch self {
        case .hearts: return MoodStyle(eyes: "heart", mouth: "smile", anim: "bob", fx: ["hearts", "blush"], color: color, texts: [])
        case .wave, .spin: return MoodStyle(eyes: "sparkle", mouth: "grin", anim: "none", fx: [], color: color, texts: [])
        case .wiggle: return MoodStyle(eyes: "happy", mouth: "smile", anim: "none", fx: ["blush"], color: color, texts: [])
        case .cute: return MoodStyle(eyes: "heart", mouth: "small", anim: "breathe", fx: ["hearts", "blush"], color: color, texts: [])
        case .tickle: return MoodStyle(eyes: "happy", mouth: "grin", anim: "none", fx: ["blush", "sweat"], color: color, texts: [])
        case .laugh: return MoodStyle(eyes: "happy", mouth: "grin", anim: "none", fx: ["blush", "notes"], color: color, texts: [])
        case .dizzy: return MoodStyle(eyes: "x", mouth: "wobble", anim: "none", fx: ["stars"], color: color, texts: [])
        case .knocked: return MoodStyle(eyes: "x", mouth: "scream", anim: "none", fx: ["stars"], color: color, texts: [])
        }
    }
}

/// Mouse interaction state. Fed by an AppKit tracking area on the panel
/// (SwiftUI `.onHover` is unreliable in a non-activating panel of an
/// accessory app). Only the pet is the hot zone, not the whole widget.
@MainActor
@Observable
final class PetHoverModel {
    static let shared = PetHoverModel()

    /// Pet area in the hosting view's (top-left origin) coordinates.
    var petRect: CGRect = .zero
    private(set) var isHovering = false

    @ObservationIgnored private var samples: [(t: Double, p: CGPoint)] = []
    @ObservationIgnored private var oneShot: (r: HoverReaction, start: Double)?
    @ObservationIgnored private var greeting: HoverReaction = .hearts
    @ObservationIgnored private var lastGreeting: HoverReaction?
    @ObservationIgnored private var hoverStart: Double = 0
    @ObservationIgnored private var leftAt: Double?
    @ObservationIgnored private var tickleUntil: Double = 0
    @ObservationIgnored private var dizzyCooldownUntil: Double = 0

    private var hotRect: CGRect {
        guard petRect.width > 0 else { return .zero }
        let w = min(petRect.width, max(petRect.height * 1.6, 40))
        return CGRect(x: petRect.midX - w / 2, y: petRect.minY, width: w, height: petRect.height).insetBy(dx: -6, dy: -6)
    }

    private static func now() -> Double { PixelTime.milliseconds(Date()) }

    private func startOneShot(_ r: HoverReaction, at t: Double) {
        if let o = oneShot, t - o.start < o.r.duration, o.r != .laugh { return } // don't interrupt a fall / dizzy
        oneShot = (r, t)
        samples.removeAll()
    }

    // MARK: input

    func pointer(at p: CGPoint?) {
        let t = Self.now()
        if let p {
            samples.append((t, p))
            samples.removeAll { t - $0.t > 1500 }
        }
        let inside = p.map { hotRect.contains($0) } ?? false

        if inside && !isHovering {
            isHovering = true
            leftAt = nil
            hoverStart = t
            // Entry speed over the last ~90 ms: a fast sweep knocks the pet over.
            let recent = samples.filter { t - $0.t <= 90 }
            if let first = recent.first, let last = recent.last, last.t > first.t {
                let dx = last.p.x - first.p.x, dy = last.p.y - first.p.y
                let speed = hypot(dx, dy) / (last.t - first.t) // pt per ms
                if speed > 1.3 {
                    startOneShot(.knocked(dir: dx >= 0 ? 1 : -1), at: t)
                    return
                }
            }
            var next = HoverReaction.greetings.randomElement() ?? .hearts
            if next == lastGreeting { next = HoverReaction.greetings.first { $0 != lastGreeting } ?? next }
            lastGreeting = next
            greeting = next
        } else if !inside && isHovering {
            isHovering = false
            leftAt = t
        }

        guard inside else { return }

        // Rubbing / tickling detection over the pointer path on the pet.
        let onPet = samples.filter { hotRect.insetBy(dx: -10, dy: -10).contains($0.p) }
        guard onPet.count >= 3 else { return }
        var length: CGFloat = 0
        var reversals = 0
        var lastSignX: CGFloat = 0, lastSignY: CGFloat = 0
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for i in 1..<onPet.count {
            let dx = onPet[i].p.x - onPet[i - 1].p.x, dy = onPet[i].p.y - onPet[i - 1].p.y
            length += hypot(dx, dy)
            if abs(dx) > 1.5 { let s: CGFloat = dx > 0 ? 1 : -1; if lastSignX != 0 && s != lastSignX { reversals += 1 }; lastSignX = s }
            if abs(dy) > 1.5 { let s: CGFloat = dy > 0 ? 1 : -1; if lastSignY != 0 && s != lastSignY { reversals += 1 }; lastSignY = s }
        }
        for s in onPet { minX = min(minX, s.p.x); maxX = max(maxX, s.p.x); minY = min(minY, s.p.y); maxY = max(maxY, s.p.y) }
        let span = max(maxX - minX, maxY - minY)

        if (length > 1600 || reversals >= 14) && t > dizzyCooldownUntil {
            startOneShot(.dizzy, at: t)
            dizzyCooldownUntil = t + 5000
        } else if reversals >= 5 && span < 45 {
            tickleUntil = t + 900
        }
    }

    /// Click on the pet.
    func poke() { startOneShot(.laugh, at: Self.now()) }

    // MARK: output

    /// Current reaction + elapsed ms, or nil when idle.
    func active(at time: Double) -> (HoverReaction, Double)? {
        if let o = oneShot {
            let e = time - o.start
            if e >= 0 && e < o.r.duration { return (o.r, e) }
            oneShot = nil
            hoverStart = time // restart the hover loop cleanly after a one-shot
        }
        if !isHovering {
            guard let leftAt, time - leftAt < 300 else { return nil }
        }
        let loopOf: (HoverReaction) -> Double = { r in
            let e = max(0, time - self.hoverStart).truncatingRemainder(dividingBy: r.duration)
            return min(e, r.duration - 260) // keep bubble visible while hovering
        }
        if time < tickleUntil { return (.tickle, loopOf(.tickle)) }
        // Held still on the pet for a while → cute.
        let lastMove = samples.last?.t ?? hoverStart
        if isHovering && time - hoverStart > 1200 && time - lastMove > 1000 {
            return (.cute, loopOf(.cute))
        }
        return (greeting, loopOf(greeting))
    }
}

/// Owner object for the panel's NSTrackingArea; converts window points to
/// the hosting view's flipped coordinates.
final class PetHoverTracker: NSResponder {
    weak var view: NSView?

    private func report(_ event: NSEvent?) {
        let point: CGPoint? = {
            guard let event, let view else { return nil }
            return view.convert(event.locationInWindow, from: nil)
        }()
        MainActor.assumeIsolated { PetHoverModel.shared.pointer(at: point) }
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { report(nil) }
}

private struct PetFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Publishes this view's frame as the pet hot zone, and pokes on click.
    func reportPetFrame() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: PetFrameKey.self, value: proxy.frame(in: .global))
            }
        )
        .onPreferenceChange(PetFrameKey.self) { rect in
            MainActor.assumeIsolated { PetHoverModel.shared.petRect = rect }
        }
        .contentShape(Rectangle())
        .onTapGesture { MainActor.assumeIsolated { PetHoverModel.shared.poke() } }
    }
}

enum PetHover {
    /// Moods whose face must stay readable: gentle reactions only add a bubble.
    /// Physical one-shots (knocked, dizzy, laugh) always play on the pet.
    private static func keepsFace(_ base: PetMood) -> Bool {
        switch base {
        case .sleeping, .panic, .stressed, .worried, .dizzy, .confused, .celebrate: return true
        default: return false
        }
    }

    /// Style override for the renderer, or nil to draw the base mood as-is.
    static func style(base: PetMood, reaction r: HoverReaction) -> MoodStyle? {
        guard base != .vacation else { return nil }
        if !r.isOneShot && keepsFace(base) { return nil }
        let color = MoodStyles.table[base]?.color ?? PetPalette.green
        return r.style(color: color)
    }

    static func bubbleText(base: PetMood, reaction r: HoverReaction, elapsed e: Double) -> String {
        if case .knocked = r { return e < 1300 ? "Oof!" : "Hey!!" }
        if r.isOneShot { return r.bubble }
        switch base {
        case .sleeping: return "5 more min…"
        case .vacation: return "Shh… on break"
        case .panic, .stressed: return "Save me!!"
        case .worried: return "Slow down?"
        case .dizzy: return "Wifi…?"
        case .confused: return "Huh?"
        case .lonely: return r == .cute ? "Link me? <3" : "Link me? :)"
        default: return r.bubble
        }
    }

    /// Body motion for the reaction, applied around the pet.
    static func applyMotion(_ r: HoverReaction, base: PetMood, elapsed e: Double, center c: CGPoint, pixel P: CGFloat, to ctx: inout GraphicsContext, reduceMotion: Bool) {
        guard !reduceMotion, style(base: base, reaction: r) != nil else { return }
        let feet = CGPoint(x: c.x, y: c.y + 5 * P)
        func rotate(_ a: Double, around p: CGPoint) {
            ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: .radians(a)); ctx.translateBy(x: -p.x, y: -p.y)
        }
        func scale(_ sx: CGFloat, _ sy: CGFloat, around p: CGPoint) {
            ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: sx, y: sy); ctx.translateBy(x: -p.x, y: -p.y)
        }
        switch r {
        case .hearts:
            let s = 1 + 0.06 * sin(e / 120); scale(s, s, around: c)
        case .wave:
            ctx.translateBy(x: 0, y: -abs(sin(e / 180)) * P * 2.5)
        case .wiggle:
            scale(1 + 0.12 * sin(e / 60), 1 - 0.1 * sin(e / 60), around: feet)
        case .spin:
            let q = min(1, e / 900)
            ctx.translateBy(x: 0, y: -sin(q * .pi) * P * 4)
            rotate(q * 2 * .pi, around: c)
        case .cute:
            let s = 1 + 0.04 * sin(e / 300)
            rotate(sin(e / 700) * 0.08, around: feet); scale(s, s, around: feet)
        case .tickle:
            ctx.translateBy(x: sin(e / 32) * P * 0.7, y: -abs(cos(e / 45)) * P * 0.8)
            scale(1 + 0.08 * sin(e / 50), 1 - 0.08 * sin(e / 50), around: feet)
        case .laugh:
            ctx.translateBy(x: 0, y: -abs(sin(e / 110)) * P * 2)
            scale(1 + 0.06 * sin(e / 55), 1 - 0.06 * sin(e / 55), around: feet)
        case .dizzy:
            ctx.translateBy(x: sin(e / 140) * P, y: 0)
            rotate(sin(e / 140) * 0.28, around: feet)
        case .knocked(let dir):
            // fall (0–220 ms) → lie (to 1300) → get up (to 1700) → settle
            let fall = min(1, e / 220)
            let up = e > 1300 ? min(1, (e - 1300) / 400) : 0
            let eased = 1 - pow(1 - fall, 3)
            let angle = Double(dir) * (.pi / 2) * eased * (1 - up)
            let bounce = e > 220 && e < 420 ? -sin((e - 220) / 200 * .pi) * P * 0.8 : 0
            ctx.translateBy(x: dir * P * 2 * eased * (1 - up), y: bounce)
            rotate(angle, around: CGPoint(x: feet.x + dir * 6 * P, y: feet.y))
        }
    }

    /// Pixel speech bubble above-right of the pet.
    static func drawBubble(_ text: String, elapsed e: Double, total: Double, anchor a: CGPoint, pixel P: CGFloat, in ctx: inout GraphicsContext, font: (CGFloat, Bool) -> Font) {
        let fadeIn = min(1, e / 150), fadeOut = min(1, (total - e) / 250)
        let alpha = max(0, min(fadeIn, fadeOut))
        guard alpha > 0 else { return }
        let size = max(7, P * 1.8)
        let w = CGFloat(text.count) * size * 0.72 + P * 2, h = size + P * 1.4
        let rect = CGRect(x: a.x, y: a.y - h, width: w, height: h)
        var c = ctx
        c.opacity = alpha
        c.fill(Path(roundedRect: rect, cornerRadius: P * 0.8), with: .color(LCD.ink))
        var tail = Path()
        tail.move(to: CGPoint(x: rect.minX + P, y: rect.maxY))
        tail.addLine(to: CGPoint(x: rect.minX + P * 2.2, y: rect.maxY))
        tail.addLine(to: CGPoint(x: rect.minX + P * 0.4, y: rect.maxY + P * 1.2))
        tail.closeSubpath()
        c.fill(tail, with: .color(LCD.ink))
        c.draw(Text(text).font(font(size, true)).foregroundColor(LCD.screen), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}
#endif
