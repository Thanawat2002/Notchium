import AppKit
import ApplicationServices

/// On-screen frame (AppKit bottom-left, clipped to the visible area) for a
/// specific sub-zone, mapping the tile's normalized region onto the display.
/// Shared by the drag monitor (to snap) and the preview overlay.
enum SnapZones {
    static func frame(_ target: SnapTarget, on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let kinds = LayoutKind.allCases
        guard target.tile < kinds.count else { return vf }
        let regions = kinds[target.tile].regions
        guard target.region < regions.count else { return vf }
        let r = regions[target.region]                 // normalized, top-left origin
        let w = r.width * vf.width
        let h = r.height * vf.height
        let x = vf.minX + r.minX * vf.width
        let y = vf.maxY - r.minY * vf.height - h       // flip to AppKit bottom-left
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Accessibility (AX) permission gate. Reading and moving *other apps'* windows
/// needs the app to be trusted in System Settings → Privacy → Accessibility.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt the user (shows the system dialog + deep-links to Settings). The
    /// return value is the trust state *now* — granting usually completes after
    /// the user flips the switch, so callers should re-check later.
    @discardableResult
    static func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Watches for a window being dragged toward the notch and drives
/// `model.snapPhase` (off → armed → picker). Detection is global-mouse based;
/// AX is used only to confirm the pointer grabbed a real window and that the
/// window actually moved (so scrolling / text-selection never arms it).
///
/// Actually snapping the window into a chosen layout is a later step — this
/// stage just recognises the gesture and opens the picker.
@MainActor
final class WindowSnapController {
    private let model: NotchModel
    private var monitors: [Any] = []

    private var draggedWindow: AXUIElement?
    private var startPos: CGPoint?
    private var startMouse: NSPoint = .zero
    private var isWindowDrag = false
    private var latchedPicker = false

    /// How close to the top edge (points) counts as "armed" while dragging.
    private let armThreshold: CGFloat = 160
    /// Distance from the top edge that opens the picker. Generous, because a
    /// dragged window's title bar stops at the menu bar — the cursor can't reach
    /// the very top pixel.
    private let pickerThreshold: CGFloat = 48
    /// Half-width of the centered zone at the top that opens the picker.
    private let pickerHalfWidth: CGFloat = 150

    init(model: NotchModel) { self.model = model }

    /// Begin watching, but only once Accessibility is granted — otherwise we
    /// can't tell a window drag from any other drag, so we stay inert.
    func start() {
        guard Accessibility.isTrusted, monitors.isEmpty else { return }
        install()
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    private func install() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    // MARK: Gesture tracking

    private func mouseDown() {
        draggedWindow = Self.windowUnderPointer()
        startPos = draggedWindow.flatMap(Self.position(of:))
        startMouse = NSEvent.mouseLocation
        isWindowDrag = false
        latchedPicker = false
    }

    private func mouseDragged() {
        guard let win = draggedWindow else { return }
        // Confirm it's a real window move (not a scroll / selection) by checking
        // the window's own position actually changed.
        if !isWindowDrag {
            // Prefer confirming via the window's own position change (filters out
            // scroll / text-selection). But some apps (Electron: Spotify, Claude)
            // only update AX position on drop, so also accept once the cursor has
            // clearly moved — otherwise those windows would never arm.
            let windowMoved: Bool
            if let start = startPos, let now = Self.position(of: win) {
                windowMoved = abs(now.x - start.x) + abs(now.y - start.y) >= 4
            } else {
                windowMoved = true          // no position info → can't gate on it
            }
            let m = NSEvent.mouseLocation
            let cursorMoved = abs(m.x - startMouse.x) + abs(m.y - startMouse.y) >= 8
            guard windowMoved || cursorMoved else { return }
            isWindowDrag = true
        }
        updatePhase()
    }

    private func mouseUp() {
        // Dropping while a sub-zone is selected snaps the window into it.
        if model.snapPhase == .picker, let target = model.snapTarget, let win = draggedWindow,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            snap(win, to: target, on: screen)
        }
        if model.snapPhase != .off { model.snapPhase = .off }
        model.snapTarget = nil
        model.snapPreviewFrame = nil
        draggedWindow = nil
        startPos = nil
        isWindowDrag = false
        latchedPicker = false
    }

    private func updatePhase() {
        let p = NSEvent.mouseLocation
        let phase = phase(for: p)
        if phase == .picker { latchedPicker = true }
        if model.snapPhase != phase { model.snapPhase = phase }

        // While the picker is open, track which sub-zone the pointer is over and
        // preview it on screen.
        if phase == .picker, let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            let target = target(for: p, on: screen)
            if model.snapTarget != target { model.snapTarget = target }
            let frame = target.map { SnapZones.frame($0, on: screen) }
            if model.snapPreviewFrame != frame { model.snapPreviewFrame = frame }
        } else {
            if model.snapTarget != nil { model.snapTarget = nil }
            if model.snapPreviewFrame != nil { model.snapPreviewFrame = nil }
        }
    }

    // MARK: Tile hit-testing + snapping

    /// Which sub-zone (tile + region) the pointer is over, matching the exact
    /// positions `SnapPickerView` draws from `PickerMetrics`. Nil if not over a tile.
    private func target(for p: NSPoint, on screen: NSScreen) -> SnapTarget? {
        let inset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let contentW = model.snapPickerSize.width
        let contentTopY = screen.frame.maxY - inset            // screen y of content top edge
        let contentLeftX = screen.frame.midX - contentW / 2
        let rowTopY = contentTopY - PickerMetrics.rowTop       // top of the tile row
        let rowBottomY = rowTopY - PickerMetrics.tileH
        let tol: CGFloat = 12                                  // grace band so a fast sweep never drops out
        guard p.y <= rowTopY + tol, p.y >= rowBottomY - tol else { return nil }

        let firstLeft = contentLeftX + PickerMetrics.tileLeft(0, contentWidth: contentW)
        let pitch = PickerMetrics.tileW + PickerMetrics.gap
        let lastRight = firstLeft + CGFloat(PickerMetrics.count - 1) * pitch + PickerMetrics.tileW
        guard p.x >= firstLeft - tol, p.x <= lastRight + tol else { return nil }

        // Nearest tile by pitch — a point in the gap between tiles snaps to the
        // tile on its left instead of returning nil (which made the preview blink).
        let i = min(PickerMetrics.count - 1, max(0, Int((p.x - firstLeft) / pitch)))
        let left = firstLeft + CGFloat(i) * pitch
        let nx = min(0.999, max(0, (p.x - left) / PickerMetrics.tileW))
        let ny = min(0.999, max(0, (rowTopY - p.y) / PickerMetrics.tileH))
        let regions = LayoutKind.allCases[i].regions
        let region = regions.firstIndex(where: { $0.contains(CGPoint(x: nx, y: ny)) }) ?? 0
        return SnapTarget(tile: i, region: region)
    }

    /// Move + resize the window into the chosen sub-zone via AX.
    private func snap(_ win: AXUIElement, to target: SnapTarget, on screen: NSScreen) {
        let ak = SnapZones.frame(target, on: screen)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var origin = CGPoint(x: ak.minX, y: primaryTop - ak.maxY)   // AppKit → AX top-left
        var size = CGSize(width: ak.width, height: ak.height)

        func setPosition() {
            if let v = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            }
        }
        setPosition()
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
        setPosition()   // re-apply: some apps clamp size first, nudging the origin
    }

    /// Map the cursor position to a snap phase. Once the picker opens it stays
    /// open until release, so pulling the pointer down onto a tile keeps it up.
    private func phase(for p: NSPoint) -> SnapPhase {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) })
        else { return latchedPicker ? .picker : .off }
        if latchedPicker { return .picker }
        let dy = screen.frame.maxY - p.y                     // distance from the top edge
        let centered = abs(p.x - screen.frame.midX) < pickerHalfWidth
        if dy <= pickerThreshold && centered { return .picker }   // up at the island
        if dy <= armThreshold { return .armed }
        return .off
    }

    // MARK: AX helpers

    /// The window being grabbed: first the element under the pointer, then a
    /// fallback to the frontmost app's focused window (Electron apps like
    /// Spotify / Claude draw custom title bars, so element-at-point finds no AX
    /// window). Nil if neither resolves / not trusted.
    private static func windowUnderPointer() -> AXUIElement? {
        let m = NSEvent.mouseLocation
        // AX uses a top-left origin measured from the primary display; NSEvent
        // uses bottom-left. Flip through the primary screen's height.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: m.x, y: primaryTop - m.y)

        var element: AXUIElement?
        let sys = AXUIElementCreateSystemWide()
        if AXUIElementCopyElementAtPosition(sys, Float(axPoint.x), Float(axPoint.y), &element) == .success,
           let element, let window = enclosingWindow(element) {
            return window
        }
        return focusedWindowOfFrontApp()
    }

    /// The focused window of whichever app is frontmost (the one just grabbed).
    private static func focusedWindowOfFrontApp() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        return (window as! AXUIElement)
    }

    /// Walk up the AX hierarchy until we hit the window element.
    private static func enclosingWindow(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 8 {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == (kAXWindowRole as String) {
                return node
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { return nil }
            current = (parent as! AXUIElement)
            depth += 1
        }
        return nil
    }

    /// Top-left position of a window in AX coordinates.
    private static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }
}
