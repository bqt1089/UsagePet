#if os(macOS)
import SwiftUI
import AppKit
import ClaudeUsageCore

/// Cute reaction the pet plays when the mouse hovers the widget.
enum HoverReaction: CaseIterable {
    case hearts   // heart eyes + floating hearts
    case wave     // happy bounce, "Hi!"
    case wiggle   // tickled squash & stretch
    case spin     // little backflip

    static let duration: Double = 2400 // ms

    var bubble: String {
        switch self {
        case .hearts: return "<3 hehe"
        case .wave: return "Hi!"
        case .wiggle: return "Tickles!"
        case .spin: return "Wheee!"
        }
    }

    /// Sprite mood used while reacting.
    var mood: PetMood {
        switch self {
        case .hearts: return .love
        case .wave: return .ecstatic
        case .wiggle: return .happy
        case .spin: return .ecstatic
        }
    }
}

/// Global hover state, fed by an AppKit tracking area on the panel (SwiftUI
/// `.onHover` doesn't fire reliably in a non-activating panel of an
/// accessory app).
@MainActor
@Observable
final class PetHoverModel {
    static let shared = PetHoverModel()
    private(set) var startedAt: Double?
    private(set) var reaction: HoverReaction = .hearts
    private var last: HoverReaction?

    func entered() {
        var next = HoverReaction.allCases.randomElement() ?? .hearts
        if next == last { next = HoverReaction.allCases.first { $0 != last } ?? next }
        last = next
        reaction = next
        startedAt = PixelTime.milliseconds(Date())
    }

    func exited() { startedAt = nil }

    /// Active reaction + elapsed ms, or nil when idle.
    func active(at time: Double) -> (HoverReaction, Double)? {
        guard let startedAt else { return nil }
        let elapsed = time - startedAt
        guard elapsed >= 0, elapsed < HoverReaction.duration else { return nil }
        return (reaction, elapsed)
    }
}

/// Owner object for the panel's NSTrackingArea.
final class PetHoverTracker: NSResponder {
    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { PetHoverModel.shared.entered() }
    }
    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { PetHoverModel.shared.exited() }
    }
}

enum PetHover {
    /// What the sprite should show. Moods that must stay readable keep their
    /// face and only get a speech bubble.
    static func shownMood(base: PetMood, reaction: HoverReaction) -> PetMood {
        switch base {
        case .sleeping, .vacation, .panic, .stressed, .worried, .dizzy, .confused, .celebrate:
            return base
        default:
            return reaction.mood
        }
    }

    static func bubbleText(base: PetMood, reaction: HoverReaction) -> String {
        switch base {
        case .sleeping: return "5 more min…"
        case .vacation: return "Shh… on break"
        case .panic, .stressed: return "Save me!!"
        case .worried: return "Slow down?"
        case .dizzy: return "Wifi…?"
        case .confused: return "Huh?"
        case .lonely: return "Link me? :)"
        default: return reaction.bubble
        }
    }

    /// Applies the reaction's body motion around the pet's center.
    static func applyMotion(_ reaction: HoverReaction, base: PetMood, elapsed e: Double, center c: CGPoint, pixel P: CGFloat, to ctx: inout GraphicsContext, reduceMotion: Bool) {
        guard !reduceMotion, shownMood(base: base, reaction: reaction) != base || base == .lonely else { return }
        let p = e / HoverReaction.duration
        switch reaction {
        case .hearts:
            let s = 1 + 0.06 * sin(e / 120)
            ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -c.x, y: -c.y)
        case .wave:
            let hop = abs(sin(e / 180)) * P * 2.5 * (1 - p)
            ctx.translateBy(x: 0, y: -hop)
        case .wiggle:
            let sx = 1 + 0.12 * sin(e / 60) * (1 - p), sy = 1 - 0.1 * sin(e / 60) * (1 - p)
            ctx.translateBy(x: c.x, y: c.y + 5 * P); ctx.scaleBy(x: sx, y: sy); ctx.translateBy(x: -c.x, y: -(c.y + 5 * P))
        case .spin:
            let q = min(1, e / 900)
            let angle = q * 2 * .pi
            let hop = sin(q * .pi) * P * 4
            ctx.translateBy(x: c.x, y: c.y - hop); ctx.rotate(by: .radians(angle)); ctx.translateBy(x: -c.x, y: -c.y)
        }
    }

    /// Pixel speech bubble above-right of the pet.
    static func drawBubble(_ text: String, elapsed e: Double, anchor a: CGPoint, pixel P: CGFloat, in ctx: inout GraphicsContext, font: (CGFloat, Bool) -> Font) {
        let fadeIn = min(1, e / 150), fadeOut = min(1, (HoverReaction.duration - e) / 250)
        let alpha = max(0, min(fadeIn, fadeOut))
        guard alpha > 0 else { return }
        let size = max(7, P * 1.8)
        let w = CGFloat(text.count) * size * 0.72 + P * 2, h = size + P * 1.4
        let rect = CGRect(x: a.x, y: a.y - h, width: w, height: h)
        var c = ctx
        c.opacity = alpha
        c.fill(Path(roundedRect: rect, cornerRadius: P * 0.8), with: .color(LCD.ink))
        // tail
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
