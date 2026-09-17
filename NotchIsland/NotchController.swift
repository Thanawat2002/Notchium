import SwiftUI
import Combine

/// Owns the borderless floating panel that hosts the notch and keeps it
/// pinned to the top-center of the **active screen** — the one the cursor is
/// currently on — resizing as the state changes.
///
/// Hover is detected by sampling the global cursor position against fixed
/// screen-space zones — never from the panel itself, whose bounds change as
/// it resizes (which would cause the expand/collapse to oscillate). A small
/// "open" zone triggers expansion; a larger "stay open" zone (the expanded
/// footprint) keeps it open, giving hysteresis so the edge never chatters.
///
/// Multi-display (Phase 4, "follow active"): the island lives on whichever
/// screen holds the cursor. Screens with a real notch use it; screens without
/// one get a "fake notch" pill (notchWidth 0 → the pill draws its own shape).
@MainActor
final class NotchController {
    private let model: NotchModel
    private let panel: NSPanel
    private let margin: CGFloat = 14
    /// Space reserved at the very top for the physical notch / menu bar of the
    /// screen the island currently lives on.
    private var topInset: CGFloat = 0

    /// The screen the island is currently pinned to.
    private var currentScreen: NSScreen?

    private var hoverTimer: Timer?
    private var hoverOutAt: Date?
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    init(model: NotchModel) {
        self.model = model

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar                 // sits above the menu bar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // shadow is drawn in SwiftUI
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: NotchRootView(model: model, margin: margin))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Adopt whichever screen has a real notch to start (or the main one).
        adopt(Self.pickScreen())

        // Re-lay out whenever the model changes (hover, pin, kind…).
        cancellable = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.layout(animated: true) }
        }

        // Recompute when displays are added/removed or rearranged.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    deinit {
        hoverTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        layout(animated: false)
        panel.orderFrontRegardless()
        startHoverTracking()
    }

    // MARK: Active-screen tracking

    /// Point the island at `screen`: update its notch geometry + clearance.
    /// Does not animate — screen switches snap so the island never slides
    /// across the gap between displays.
    private func adopt(_ screen: NSScreen?) {
        currentScreen = screen
        topInset = Self.notchInset(for: screen)
        model.topInset = topInset
        model.notchWidth = Self.notchWidth(for: screen)
        // Only match the notch height when there's a real notch; otherwise keep
        // the 32pt spec height (menu-bar height would make the pill too short).
        let hasNotch = (screen?.safeAreaInsets.top ?? 0) > 0
        model.notchHeight = hasNotch ? Self.notchInset(for: screen) : 0
    }

    /// The screen the cursor is currently on (falls back to the current one).
    private func activeScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(p) })
            ?? currentScreen ?? Self.pickScreen()
    }

    /// Displays changed — re-adopt the current screen (its notch dims may have
    /// changed) or move to a valid one if ours went away.
    private func screensChanged() {
        if let cur = currentScreen, NSScreen.screens.contains(cur) {
            adopt(cur)
        } else {
            adopt(activeScreen())
        }
        layout(animated: false)
    }

    // MARK: Hover tracking

    private func startHoverTracking() {
        // The timer runs on the main run loop, so the callback is already on
        // the main actor — assume that isolation rather than hopping.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func sampleHover() {
        // Pinned open: stay put on the current screen, don't chase the cursor.
        guard !model.pinned else { return }

        // Follow the cursor to another display. Only re-home while fully
        // collapsed — never yank an open island out from under the pointer.
        if let active = activeScreen(), active !== currentScreen,
           model.presentation == .collapsed {
            adopt(active)
            layout(animated: false)             // snap onto the new screen
        }

        guard let screen = currentScreen else { return }
        let p = NSEvent.mouseLocation                     // global, origin bottom-left
        let target = desiredZone(at: p, on: screen)

        if target != .none {
            hoverOutAt = nil
            if model.hoverZone != target {
                // Haptic only when first engaging from idle, not on internal
                // strip → drop transitions.
                let engaging = model.hoverZone == .none
                model.hoverZone = target
                if engaging { Haptics.engage() }
            }
        } else if model.hoverZone != .none {
            // Leaving waits a grace period so a corner-cross doesn't flicker.
            if let deadline = hoverOutAt {
                if Date() >= deadline {
                    model.hoverZone = .none
                    hoverOutAt = nil
                }
            } else {
                hoverOutAt = Date().addingTimeInterval(Motion.hoverOutDelay)
            }
        } else {
            hoverOutAt = nil
        }
    }

    /// Resolve the pointer position into a hover zone. The top strip is split by
    /// horizontal position: the **center** column (over the notch) opens the
    /// full card, the **flanks** on either side open the side controls.
    ///   • collapsed / sideControls — center → card, flanks → side controls.
    ///   • expanded — sticky across the whole card footprint, so reaching for a
    ///     control never collapses it.
    private func desiredZone(at p: NSPoint, on screen: NSScreen) -> HoverZone {
        switch model.presentation {
        case .expanded:
            return stayZone(on: screen).contains(p) ? .drop : .none
        case .collapsed, .sideControls:
            if centerZone(on: screen).contains(p) { return .drop }
            if stripZone(on: screen).contains(p) { return .strip }
            return .none
        }
    }

    /// Central column of the strip, over the notch. Hovering here opens the full
    /// card; the flanks on either side open the side controls.
    private func centerZone(on screen: NSScreen) -> NSRect {
        let strip = stripZone(on: screen)
        let w = max(120, model.notchWidth + 40)
        return NSRect(x: screen.frame.midX - w / 2,
                      y: strip.minY, width: w, height: strip.height)
    }

    /// Thin band across the very top, over the pill and its side-controls width.
    private func stripZone(on screen: NSScreen) -> NSRect {
        let w = model.sideControlsSize.width + 24
        let h = model.collapsedSize.height + 10
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    /// The expanded footprint plus slack — hovering anywhere here keeps it open.
    private func stayZone(on screen: NSScreen) -> NSRect {
        let w = model.expandedSize.width + 20
        let h = model.expandedSize.height + topInset + 16
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    // MARK: Layout

    private static func pickScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Notch/menu-bar height for a screen (menu bar area kept clear at top).
    private static func notchInset(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Physical width of the display's notch, measured as the gap between the
    /// menu-bar areas on either side of it. Returns 0 on non-notched screens.
    private static func notchWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }

    private func layout(animated: Bool) {
        guard let screen = currentScreen else { return }
        let size = model.contentSize
        let inset = model.isExpanded ? topInset : 0   // clearance only when expanded
        let w = size.width + margin * 2
        let h = size.height + inset + margin
        let frame = NSRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - h,
            width: w,
            height: h)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                // Collapse is faster than expand; ease-out matches the SwiftUI spring.
                ctx.duration = model.isExpanded ? Motion.windowExpand : Motion.windowCollapse
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
