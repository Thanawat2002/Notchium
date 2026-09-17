import SwiftUI

// MARK: - Root

/// The full contents of the floating panel: a black notch shape (square top
/// corners, rounded bottom) pinned to the top-center, sized from the window
/// so it animates smoothly as the panel resizes.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    /// Transparent breathing room around the notch for the drop shadow.
    let margin: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // Only reserve the notch clearance while expanded; collapsed hugs
            // the top so its content flanks the notch left and right.
            // Clearance follows the active screen's notch / menu-bar height.
            let inset = model.isExpanded ? model.topInset : 0
            let nw = max(0, geo.size.width - margin * 2)   // side margins
            let nh = max(0, geo.size.height - margin)       // bottom margin only
            let contentH = max(0, nh - inset)               // usable area below the notch
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: radius(forContentHeight: contentH),
                bottomTrailingRadius: radius(forContentHeight: contentH),
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .overlay(alignment: .top) {
                contentLayer
                    .frame(width: nw, height: contentH)
                    .padding(.top, inset)
            }
            .frame(width: nw, height: nh)
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 5)
            // Pin is toggled from the menu bar only — clicking the notch used to
            // pin it by accident (a missed button tap kept it stuck open).
            // Hide entirely when idle (no music, not interacting); hovering the
            // notch zone still re-shows it since hover is tracked by cursor
            // position, not by whether the view is visible.
            .opacity(notchVisible ? 1 : 0)
            .animation(notchVisible ? Motion.fadeIn : Motion.fadeOut, value: notchVisible)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }

    private var notchVisible: Bool {
        model.isExpanded || model.hasNowPlaying || model.micMuted || model.outputMuted
    }

    /// Interpolate the bottom corner radius (12 collapsed → 26 expanded) from
    /// the live content height, so it tracks the panel's resize animation.
    private func radius(forContentHeight h: CGFloat) -> CGFloat {
        let minH = model.collapsedSize.height
        let maxH = model.expandedSize.height
        let t = min(1, max(0, (h - minH) / (maxH - minH)))
        return 12 + t * (26 - 12)
    }

    @ViewBuilder private var contentLayer: some View {
        ZStack {
            switch model.presentation {
            case .expanded:
                switch model.expandedKind {
                case .nowPlaying:   NowPlayingView(model: model).transition(.opacity)
                case .notification: NotificationView(model: model).transition(notificationTransition)
                }
            case .collapsed, .sideControls:
                // The pill and its side-controls variant share one layout so the
                // artwork/equalizer stay put while the mute buttons slide in.
                // Appears nicely when collapsing; vanishes instantly when the
                // big card opens so there's no blurry flash of the small pill.
                CollapsedView(model: model, showControls: model.presentation == .sideControls)
                    .transition(.asymmetric(insertion: morphTransition, removal: .identity))
            }
        }
        .animation(reduceMotion ? Motion.fadeIn : (model.isExpanded ? Motion.expand : Motion.collapse),
                   value: model.presentation)
        .animation(Motion.fadeIn, value: model.expandedKind)
    }

    /// Content blurs + scales while morphing between states (plain fade if Reduce Motion).
    private var morphTransition: AnyTransition {
        reduceMotion ? .opacity : .blurScale
    }

    /// The notification "bounces" in from the top; plain fade under Reduce Motion.
    private var notificationTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.92, anchor: .top)
                .combined(with: .opacity)
                .combined(with: .offset(y: -10)),
            removal: .opacity)
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @ObservedObject var model: NotchModel
    /// When true (the `.sideControls` state) the trailing slot shows tappable
    /// mic/speaker toggles instead of passive mute indicators.
    var showControls = false
    private let mutedRed = Color(red: 1, green: 0.27, blue: 0.23)
    var body: some View {
        let h = model.collapsedSize.height
        let art = max(20, h - 10)               // fill the notch height, small inset
        HStack(spacing: 0) {
            // Blank block mirroring the trailing controls, so the notch gap
            // stays centered on the physical notch as the pill grows sideways.
            if showControls { Color.clear.frame(width: model.controlsBlock) }
            Artwork(size: art, corner: art * 0.28, showGlyph: false, image: model.artwork)
            // Keep a gap the width of the notch so the two items stay outside it.
            Spacer(minLength: model.notchWidth)
            rightSlot(h: h)
        }
        .padding(.horizontal, 14)
    }

    /// The equalizer, followed by either passive mute indicators (collapsed) or
    /// tappable mic/speaker toggles (side controls).
    @ViewBuilder private func rightSlot(h: CGFloat) -> some View {
        HStack(spacing: 4) {
            Equalizer(active: model.isPlaying, height: max(11, h * 0.34), color: model.accentColor)
            if showControls {
                IconButton(model.micMuted ? "mic.slash.fill" : "mic.fill",
                           size: h * 0.42,
                           tint: model.micMuted ? mutedRed : .white) {
                    model.toggleMicMute()
                }
                IconButton(model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           size: h * 0.42,
                           tint: model.outputMuted ? mutedRed : .white) {
                    model.toggleOutputMute()
                }
            } else {
                if model.micMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: h * 0.3))
                        .foregroundStyle(mutedRed)
                }
                if model.outputMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: h * 0.3))
                        .foregroundStyle(mutedRed)
                }
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var sharp = false
    var body: some View {
        VStack(spacing: 0) {
            // Top: artwork + title/artist + equalizer
            HStack(alignment: .top, spacing: 16) {
                Artwork(size: 74, corner: 13, showGlyph: true, image: model.artwork)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = model.sourceIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 26, height: 26)
                                .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 1)
                                // Nudge it past the corner so it reads as a badge.
                                .offset(x: 7, y: 6)
                        }
                    }
                    .staggerIn(shown, delay: Motion.staggerArtwork, reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.trackTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.trackMeta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .staggerIn(shown, delay: Motion.staggerText, reduceMotion: reduceMotion)
                // No staggerIn here — its offset/blur animation fights the
                // equalizer's own wave. Let it run free like the collapsed one.
                Equalizer(active: model.isPlaying, height: 16, color: model.accentColor)
                    .opacity(model.isPlaying ? 1 : 0.35)
            }

            // Progress sits low, just above the controls, with times at each end.
            // Only shown when the source reports a real duration/position.
            if model.hasProgress {
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Text(model.elapsed)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.16))
                            Capsule().fill(.white.opacity(0.9))
                                .frame(width: geo.size.width * model.progress)
                        }
                    }
                    .frame(height: 3)
                    Text(model.remaining)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .staggerIn(shown, delay: Motion.staggerProgress, reduceMotion: reduceMotion)
            }

            Spacer(minLength: 12)

            // Bottom: transport centered across the whole card. Mic/speaker
            // toggles live on the collapsed top strip now (the side controls),
            // so the card stays focused on playback.
            HStack(spacing: 26) {
                IconButton("backward.fill", tint: .white.opacity(0.5)) { model.previousTrack() }
                IconButton(model.isPlaying ? "pause.fill" : "play.fill", size: 27) {
                    model.playPause()
                }
                IconButton("forward.fill", tint: .white.opacity(0.5)) { model.nextTrack() }
            }
            .frame(maxWidth: .infinity)
            .staggerIn(shown, delay: Motion.staggerControls, reduceMotion: reduceMotion)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Whole panel stays blurred while it grows, then sharpens (~500ms).
        .blur(radius: (sharp || reduceMotion) ? 0 : Motion.openBlur)
        .animation(reduceMotion ? nil : Motion.openBlurClear, value: sharp)
        .onAppear { shown = true; sharp = true }
        .onDisappear { shown = false; sharp = false }
    }
}

// MARK: - Notification

struct NotificationView: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.29, green: 0.64, blue: 1.0),
                             Color(red: 0.04, green: 0.44, blue: 0.90)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "calendar")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 0) {
                Text(sourceLine)
                    .font(.system(size: 11.5))

                Text("\(model.notifLine1)\n\(model.notifLine2)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Spacer()
                    ActionButton(title: "เตือนอีกครั้ง")
                    ActionButton(title: "ปิด")
                    ActionButton(title: "เปิด", primary: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "ปฏิทิน · เมื่อสักครู่" with the app name brighter than the timestamp.
    private var sourceLine: AttributedString {
        var app = AttributedString(model.notifApp)
        app.foregroundColor = .white.opacity(0.9)
        app.font = .system(size: 11.5, weight: .semibold)
        var rest = AttributedString(" · \(model.notifWhen)")
        rest.foregroundColor = .white.opacity(0.55)
        return app + rest
    }
}

// MARK: - Transitions

/// Blurs and scales content as it enters/leaves — the Dynamic Island "morph".
struct BlurScaleModifier: ViewModifier {
    var blur: CGFloat
    var scale: CGFloat
    var opacity: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var blurScale: AnyTransition {
        .modifier(
            active: BlurScaleModifier(blur: 9, scale: 0.9, opacity: 0),
            identity: BlurScaleModifier(blur: 0, scale: 1, opacity: 1))
    }
}

// MARK: - Building blocks

struct Artwork: View {
    var size: CGFloat
    var corner: CGFloat
    var showGlyph: Bool
    var image: NSImage? = nil
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.36, green: 0.37, blue: 0.51),
                         Color(red: 0.16, green: 0.18, blue: 0.27)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else if showGlyph {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
    }
}

/// Live audio equalizer bars driven by a timeline so they animate smoothly
/// while playing and freeze when paused.
struct Equalizer: View {
    var active: Bool
    var height: CGFloat = 14
    var color: Color = Color(red: 1.0, green: 0.62, blue: 0.24)   // warm amber
    @State private var animating = false

    private let heights: [CGFloat] = [6, 14, 10, 18, 9, 16, 12]

    var body: some View {
        let scale = height / heights.max()!   // fit the tallest bar into `height`
        HStack(alignment: .center, spacing: 2.5 * scale) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(i.isMultiple(of: 2) ? color : color.opacity(0.78))
                    // Uniform height when stopped → a calm centered line.
                    .frame(width: max(2, 2.6 * scale), height: (animating ? heights[i] : 9) * scale)
                    .scaleEffect(y: animating ? 1 : 0.4, anchor: .center)
                    .animation(barAnimation(i), value: animating)
            }
        }
        .frame(height: height, alignment: .center)
        .onAppear { animating = active }
        .onChange(of: active) { _, playing in animating = playing }
    }

    /// Playing: each bar breathes on a staggered loop (the wave). Stopped: it
    /// eases down to the resting scale and holds.
    private func barAnimation(_ i: Int) -> Animation {
        animating
            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.09)
            : .easeInOut(duration: 0.2)
    }
}

/// Scales down and dims slightly while pressed (respects Reduce Motion).
struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.88
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? Motion.fadeIn : Motion.snappy, value: configuration.isPressed)
    }
}

/// Circular transport button with a hover ring and press feedback.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = .white
    var action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, size: CGFloat = 15, tint: Color = .white, action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.size = size
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.15 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.fadeIn, value: hovering)
    }
}

struct Chip: View {
    var tint: Color
    var symbol: String
    var filled: Bool = false
    var action: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(filled ? (hovering ? 0.24 : 0.16)
                                          : (hovering ? 0.18 : 0.10)))
                .frame(width: 28, height: 22)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(filled ? tint : .white))
        }
        .buttonStyle(PressableStyle(pressedScale: 0.9))
        .onHover { hovering = $0 }
        .animation(Motion.fadeIn, value: hovering)
    }
}

struct ActionButton: View {
    var title: String
    var primary: Bool = false
    var action: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableStyle(pressedScale: 0.96))
        .onHover { hovering = $0 }
        .animation(Motion.fadeIn, value: hovering)
    }

    private var background: Color {
        if primary {
            return Color(red: 0.04, green: 0.52, blue: 1.0).opacity(hovering ? 0.85 : 1)
        }
        return Color.white.opacity(hovering ? 0.22 : 0.14)
    }
}
