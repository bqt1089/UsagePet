#if os(macOS)
import AppKit
import SwiftUI

/// A borderless, non-activating floating panel that hosts the SwiftUI usage
/// card. It never takes key focus (so it never steals focus from whatever
/// app the user is in) but still supports mouse interaction, dragging, and
/// a right-click context menu via the hosted SwiftUI content.
final class WidgetPanel: NSPanel {

    private let store: UsageStore
    private var hostingView: NSHostingView<AnyView>?
    private var refitTimer: Timer?
    private let hoverTracker = PetHoverTracker()

    init(store: UsageStore) {
        self.store = store

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        let root = WidgetRootView(
            onResize: { [weak self] size in
                self?.resizeToFitContent(size)
            },
            onInvalidateShadow: { [weak self] in
                self?.invalidateShadow()
            }
        )
        .environment(store)

        let hosting = NSHostingView(rootView: AnyView(root))
        // We size the panel ourselves via onResize; letting NSHostingView
        // drive the window size fights with that (and can collapse it to 0).
        // Only publish intrinsic size (so we can measure it); we still move/resize
        // the window ourselves in applyContentSize.
        hosting.sizingOptions = [.intrinsicContentSize]
        hostingView = hosting
        contentView = hosting
        // AppKit tracking area: works even though this accessory app is never
        // active and the panel never becomes key (SwiftUI .onHover doesn't).
        hosting.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil
        ))

        setFrameAutosaveName("UsageWidget")
        if !setFrameUsingName("UsageWidget") || !isFrameUsable {
            setContentSize(NSSize(width: 240, height: 140))
            positionTopRightOfMainScreen()
        }
        startRefitSafetyTimer()
    }

    /// Saved frame is unusable if it collapsed or sits off every screen.
    private var isFrameUsable: Bool {
        guard frame.width >= 60, frame.height >= 24 else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    func resetPosition() {
        setContentSize(NSSize(width: max(frame.width, 60), height: max(frame.height, 24)))
        positionTopRightOfMainScreen()
        saveFrame(usingName: "UsageWidget")
        orderFrontRegardless()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for WidgetPanel")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionTopRightOfMainScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        setFrameOrigin(origin)
    }

    /// Resizes the panel to fit new SwiftUI content (e.g. compact toggling),
    /// anchoring the top-left corner so the widget doesn't jump around.
    private func resizeToFitContent(_ size: CGSize) {
        // Called from SwiftUI layout; resizing the window synchronously
        // re-enters AppKit layout (_NSDetectedLayoutRecursion). Defer it.
        DispatchQueue.main.async { [weak self] in
            self?.refit()
        }
    }

    /// Sizes the panel to the SwiftUI content's real fitting size. Measuring
    /// the hosting view directly is more reliable than trusting the
    /// PreferenceKey value, which can be stale after content switches.
    func refit() {
        guard let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        var fitting = hosting.intrinsicContentSize
        if fitting.width <= 20 || fitting.height <= 20 || fitting.width == NSView.noIntrinsicMetric {
            fitting = hosting.fittingSize
        }
        guard fitting.width > 20, fitting.height > 20 else { return }
        applyContentSize(fitting)
    }

    private func startRefitSafetyTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refitTimer = timer
    }

    private func applyContentSize(_ size: CGSize) {
        let target = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 else { return }
        let size = target
        var newFrame = frame
        let topLeftY = frame.origin.y + frame.size.height
        newFrame.size = size
        newFrame.origin.y = topLeftY - size.height
        setFrame(newFrame, display: true, animate: false)
        contentView?.needsDisplay = true
        saveFrame(usingName: "UsageWidget")
        invalidateShadow()
    }
}

#endif
