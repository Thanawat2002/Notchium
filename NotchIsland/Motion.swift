import SwiftUI
import AppKit

/// Subtle haptics for the notch. Wraps `NSHapticFeedbackManager` so views and
/// the controller never touch the API directly. On Macs without a Force Touch
/// trackpad the system performer is simply a no-op — nothing to guard or log.
struct Haptics {
    /// Minimum gap between taps, so brushing the hover edge back and forth
    /// doesn't buzz repeatedly.
    private static let cooldown: TimeInterval = 0.3
    @MainActor private static var lastFire: Date = .distantPast

    /// Fire when the pointer engages (latches onto) the notch. Hover-in only —
    /// never call this on hover-out.
    @MainActor
    static func engage() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= cooldown else { return }
        lastFire = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

/// Central motion tokens — reference these everywhere, never inline literals.
/// Springs drive geometry (size/position/shape); easing drives opacity/color.
/// Collapse is deliberately faster than expand.
enum Motion {
    static let expand   = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.85)
    static let snappy   = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let fadeIn   = Animation.easeOut(duration: 0.18)
    static let fadeOut  = Animation.easeIn(duration: 0.12)
    /// Spring for the staggered lift — settles a touch after the 0.18s fade/blur,
    /// so the entry blur reaches 0 before the offset finishes moving.
    static let lift     = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Entry blur amount for the Dynamic-Island-style reveal (enter only).
    static let entryBlur: CGFloat = 3

    /// Whole-panel "opening" blur: holds while the island grows, then clears.
    static let openBlur: CGFloat = 10
    /// Holds the blur for the length of the expand (~500ms), then eases it off.
    static let openBlurClear = Animation.easeOut(duration: 0.25).delay(0.35)

    /// NSPanel resize durations (AppKit can't spring) — matched to the springs above.
    static let windowExpand: Double = 0.38
    static let windowCollapse: Double = 0.28

    /// Grace period before collapsing after the pointer leaves.
    static let hoverOutDelay: TimeInterval = 0.25
    /// Dwell before *opening* on hover, so a fly-through across the top doesn't
    /// trigger. The disruptive big card waits longer than the light side controls.
    static let hoverInBig: TimeInterval = 0.22
    static let hoverInSide: TimeInterval = 0.12

    /// Staggered reveal delays: container → artwork → text → progress → controls.
    static let staggerArtwork  = 0.08
    static let staggerText     = 0.16
    static let staggerProgress = 0.20
    static let staggerControls = 0.24
}

/// Fades + lifts an element in on a delay (the staggered reveal). Leaving is
/// handled by the container, so this only choreographs entry.
struct StaggerIn: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            // Blur + opacity share the 0.18s fade so the blur clears as the
            // element appears. (Enter only — leaving is a plain container fade.)
            .blur(radius: (shown || reduceMotion) ? 0 : Motion.entryBlur)
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? Motion.fadeIn : Motion.fadeIn.delay(shown ? delay : 0),
                       value: shown)
            // Offset settles on a slightly longer spring, so the blur reaches 0
            // before the lift stops moving.
            .offset(y: (shown || reduceMotion) ? 0 : 6)
            .animation(reduceMotion ? Motion.fadeIn : Motion.lift.delay(shown ? delay : 0),
                       value: shown)
    }
}

extension View {
    func staggerIn(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(StaggerIn(shown: shown, delay: delay, reduceMotion: reduceMotion))
    }
}
