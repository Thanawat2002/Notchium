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
            let r = radius(forContentHeight: contentH)
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: r,
                bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
            ZStack {
                shape.fill(Color.black)
                // Album art, heavily blurred + dimmed, tints the now-playing card.
                if showArtBackdrop, let art = model.artwork {
                    Image(nsImage: art)
                        .resizable().scaledToFill()
                        .frame(width: nw, height: nh).clipped()
                        .blur(radius: 34)
                        .overlay(Color.black.opacity(0.34))
                        .opacity(0.9)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                contentLayer
                    .frame(width: nw, height: contentH)
                    .padding(.top, inset)
            }
            .overlay(alignment: .topTrailing) {
                // Flip between cards from the empty strip beside the notch.
                if showsCardTabs {
                    CardTabs(model: model)
                        .frame(height: inset)
                        .padding(.trailing, 18)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fadeIn, value: showsCardTabs)
            .animation(Motion.fadeIn, value: showArtBackdrop)
            .frame(width: nw, height: nh)
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
        // Show when expanded, during a snap drag, with live music or Claude
        // activity, or an active mute indicator. Hidden only when truly idle.
        model.snapActive || model.presentation != .collapsed || model.hasNowPlaying
            || model.micMuted || model.outputMuted || model.claudeGlance != nil
    }

    private var showsCardTabs: Bool {
        !model.snapActive && model.presentation == .expanded && model.topInset > 0
            && model.cardPages.count > 1 && model.cardPages.contains(model.expandedKind)
    }

    /// Blurred-artwork card background — only the expanded now-playing card.
    private var showArtBackdrop: Bool {
        !model.snapActive && model.presentation == .expanded
            && model.expandedKind == .nowPlaying && model.hasNowPlaying && model.artwork != nil
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
            if model.snapActive {
                // A window is being dragged toward the notch — the snap UI takes
                // over the island until the drag ends.
                switch model.snapPhase {
                case .picker: SnapPickerView(model: model).transition(.opacity)
                case .armed:  ArmedPill(notchWidth: model.notchWidth).transition(.opacity)
                case .off:    EmptyView()
                }
            } else {
                switch model.presentation {
                case .expanded:
                    switch model.expandedKind {
                    case .nowPlaying:   NowPlayingView(model: model).transition(.opacity)
                    case .notification: NotificationView(model: model).transition(notificationTransition)
                    case .claude:       ClaudeCardView(model: model).transition(.opacity)
                    }
                case .collapsed:
                    // Appears nicely when collapsing; vanishes instantly when the
                    // big card opens so there's no blurry flash of the small pill.
                    CollapsedView(model: model)
                        .transition(.asymmetric(insertion: morphTransition, removal: .identity))
                }
            }
        }
        .animation(reduceMotion ? Motion.fadeIn : (model.isExpanded ? Motion.expand : Motion.collapse),
                   value: model.presentation)
        .animation(Motion.fadeIn, value: model.expandedKind)
        .animation(reduceMotion ? Motion.fadeIn : (model.snapPhase == .picker ? Motion.expand : Motion.collapse),
                   value: model.snapPhase)
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
    private let mutedRed = Color(red: 1, green: 0.27, blue: 0.23)
    var body: some View {
        let h = model.collapsedSize.height
        let art = max(20, h - 10)               // fill the notch height, small inset
        HStack(spacing: 0) {
            // Artwork only when something is actually playing; otherwise the
            // Claude crab takes the leading slot while a session is active.
            if model.hasNowPlaying {
                Artwork(size: art, corner: art * 0.28, showGlyph: false, image: model.artwork)
                    .accessibilityHidden(true)
            } else if let glance = model.claudeGlance {
                ClaudeCrab(size: h * 0.62, color: glance.tint, hopping: glance.isWorking)
                    .accessibilityLabel(glance.accessibilityLabel)
            }
            // Keep a gap the width of the notch so the two items stay outside it.
            Spacer(minLength: model.notchWidth)
            rightSlot(h: h)
        }
        .padding(.horizontal, 14)
    }

    /// The equalizer (only while playing) or Claude status, followed by mute
    /// indicators. Muting itself lives in the menu and ⌃⌥⌘M.
    @ViewBuilder private func rightSlot(h: CGFloat) -> some View {
        HStack(spacing: 4) {
            if let glance = model.claudeGlance {
                if model.hasNowPlaying {
                    // Music + Claude: the crab stands in for the equalizer.
                    ClaudeCrab(size: h * 0.62, color: glance.tint, hopping: glance.isWorking)
                        .accessibilityLabel(glance.accessibilityLabel)
                } else {
                    ClaudeGlanceAccessory(glance: glance, height: h)
                }
            } else if model.hasNowPlaying {
                Equalizer(active: model.isPlaying, height: max(11, h * 0.34), color: model.accentColor)
                    .accessibilityHidden(true)
            }
            if model.micMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: h * 0.3))
                    .foregroundStyle(mutedRed)
                    .accessibilityLabel("Microphone muted")
            }
            if model.outputMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: h * 0.3))
                    .foregroundStyle(mutedRed)
                    .accessibilityLabel("Speaker muted")
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var shown = false
    @State private var sharp = false
    var body: some View {
        VStack(spacing: 0) {
            // Top: artwork + title/artist + equalizer
            HStack(alignment: .top, spacing: 16) {
                Artwork(size: 74, corner: 13, showGlyph: true, image: model.artwork)
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = model.sourceIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 26, height: 26)
                                .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 1)
                                // Nudge it past the corner so it reads as a badge.
                                .offset(x: 7, y: 6)
                                .accessibilityLabel("Playing in \(model.sourceAppName)")
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
                        .foregroundStyle(Color.dimWhite(0.55, contrast))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .staggerIn(shown, delay: Motion.staggerText, reduceMotion: reduceMotion)
                // No staggerIn here — its offset/blur animation fights the
                // equalizer's own wave. Let it run free like the collapsed one.
                Equalizer(active: model.isPlaying, height: 16, color: model.accentColor)
                    .opacity(model.isPlaying ? 1 : 0.35)
                    .accessibilityHidden(true)
            }

            // Progress sits low, just above the controls, with times at each end.
            // Only shown when the source reports a real duration/position.
            if model.hasProgress {
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Text(model.elapsed)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.dimWhite(0.16, contrast))
                            Capsule().fill(.white.opacity(0.9))
                                .frame(width: geo.size.width * model.progress)
                        }
                    }
                    .frame(height: 3)
                    Text(model.remaining)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dimWhite(0.5, contrast))
                // One element with a value, instead of two times and a mute bar.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(model.elapsed) of \(model.totalTime)")
                .staggerIn(shown, delay: Motion.staggerProgress, reduceMotion: reduceMotion)
            }

            Spacer(minLength: 12)

            // Bottom: transport centered across the whole card.
            HStack(spacing: 26) {
                IconButton("Previous Track", symbol: "backward.fill", tint: .dimWhite(0.5, contrast),
                           action: model.previousTrack)
                IconButton(model.isPlaying ? "Pause" : "Play",
                           symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 27,
                           action: model.playPause)
                IconButton("Next Track", symbol: "forward.fill", tint: .dimWhite(0.5, contrast),
                           action: model.nextTrack)
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
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.29, green: 0.64, blue: 1.0),
                             Color(red: 0.04, green: 0.44, blue: 0.90)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "calendar")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }

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
                    ActionButton(title: "Remind again")
                    ActionButton(title: "Close")
                    ActionButton(title: "Open", primary: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Calendar · Just now" with the app name brighter than the timestamp.
    private var sourceLine: AttributedString {
        var app = AttributedString(model.notifApp)
        app.foregroundColor = .white.opacity(0.9)
        app.font = .system(size: 11.5, weight: .semibold)
        var rest = AttributedString(" · \(model.notifWhen)")
        rest.foregroundColor = Color.dimWhite(0.55, contrast)
        return app + rest
    }
}

// MARK: - Claude Code

enum ClaudeTint {
    static let clay  = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let amber = Color(red: 0.937, green: 0.624, blue: 0.153)   // #EF9F27
    static let green = Color(red: 0.365, green: 0.792, blue: 0.647)   // #5DCAA5
}

extension ClaudeSession.State {
    var tint: Color {
        switch self {
        case .working: ClaudeTint.clay
        case .waiting: ClaudeTint.amber
        case .done:    ClaudeTint.green
        }
    }
}

extension ClaudeGlance {
    var tint: Color {
        switch self {
        case .working: ClaudeTint.clay
        case .waiting: ClaudeTint.amber
        case .done:    ClaudeTint.green
        }
    }
    var isWorking: Bool { if case .working = self { true } else { false } }
    var accessibilityLabel: Text {
        switch self {
        case .working: Text("Claude is working")
        case .waiting: Text("Claude needs your attention")
        case .done:    Text("Claude finished")
        }
    }
}

/// Claude Code's pixel crab (12 × 8 cells). Hops while a session is working,
/// alternating which legs are tucked like a little walk cycle, and squashes a
/// touch on landing. Holds still under Reduce Motion.
struct ClaudeCrab: View {
    /// Width in points; height follows the 12:8 grid.
    var size: CGFloat
    var color: Color
    var hopping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rows top → bottom: body, eyes (holes), arms ×2, body ×2, legs ×2.
    private static let rows: [[ClosedRange<Int>]] = [
        [2...9],
        [2...2, 4...7, 9...9],
        [0...11],
        [0...11],
        [2...9],
        [2...9],
        [2...2, 4...4, 7...7, 9...9],
        [2...2, 4...4, 7...7, 9...9],
    ]

    var body: some View {
        let animate = hopping && !reduceMotion
        let cell = size / 12
        TimelineView(.animation(paused: !animate)) { ctx in
            let t = animate ? ctx.date.timeIntervalSinceReferenceDate / Motion.crabHop : 0
            let height = abs(sin(t * .pi))              // 0 on the ground, 1 at the top
            let squash = animate ? (1 - height) * 0.1 : 0
            let stride = Int(t.rounded(.down)) % 2      // which leg pair is tucked
            Canvas { gc, _ in
                var path = Path()
                for (r, runs) in Self.rows.enumerated() {
                    for run in runs {
                        // On the last row, tuck every other leg while hopping.
                        if animate, r == 7, (run.lowerBound == 2 || run.lowerBound == 7) == (stride == 0) {
                            continue
                        }
                        path.addRect(CGRect(x: CGFloat(run.lowerBound) * cell, y: CGFloat(r) * cell,
                                            width: CGFloat(run.count) * cell, height: cell))
                    }
                }
                gc.fill(path, with: .color(color))
            }
            .frame(width: size, height: cell * 8)
            .scaleEffect(x: 1 + squash, y: 1 - squash, anchor: .bottom)
            .offset(y: -height * cell * 2.5)
        }
        .frame(width: size, height: cell * 8)
        .animation(Motion.fadeIn, value: color)
    }
}

/// Trailing detail in the pill when Claude has it to itself: the elapsed time
/// (or how many sessions are busy), a dot when it needs you, a check when done.
struct ClaudeGlanceAccessory: View {
    let glance: ClaudeGlance
    let height: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            switch glance {
            case .working(let since, let count):
                Group {
                    if count > 1 { Text(count, format: .number) } else { Text(since, style: .timer) }
                }
                .font(.system(size: height * 0.36, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.dimWhite(0.75, contrast))
                .fixedSize()
            case .waiting:
                Circle().fill(ClaudeTint.amber).frame(width: 7, height: 7)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: height * 0.34, weight: .bold))
                    .foregroundStyle(ClaudeTint.green)
            }
        }
        .accessibilityHidden(true)   // the crab carries the label
    }
}

/// The expanded Claude card: one row per session, most urgent first.
struct ClaudeCardView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    private let maxRows = 3
    var body: some View {
        let rows = Array(model.claudeSessions.prefix(maxRows))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.enumerated(), id: \.element.id) { i, session in
                if i > 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 8) }
                ClaudeSessionRow(session: session,
                                 onOpen: { model.openClaudeSession(session) },
                                 onAnswer: { model.answerClaude(session, allow: $0) })
                    .staggerIn(shown, delay: Motion.staggerArtwork + Double(i) * Motion.staggerRow,
                               reduceMotion: reduceMotion)
            }
            let more = model.claudeSessions.count - rows.count
            if more > 0 {
                Text("+\(more) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// One session. Tapping it switches to its terminal; a held permission prompt
/// adds Deny / Allow, which only arm a beat after they appear so a pointer
/// already resting where the card drops can't approve anything by accident.
struct ClaudeSessionRow: View {
    let session: ClaudeSession
    var onOpen: () -> Void = {}
    var onAnswer: (Bool) -> Void = { _ in }
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var armed = false
    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) { content }
                .buttonStyle(PressableStyle(pressedScale: 0.98))
                .disabled(session.host == nil)
                .accessibilityHint(session.host == nil ? Text("") : Text("Switches to its window"))
            if session.request != nil {
                HStack(spacing: 6) {
                    ActionButton(title: "Deny") { onAnswer(false) }
                    ActionButton(title: "Allow", primary: true) { onAnswer(true) }
                }
                .disabled(!armed)
                .opacity(armed ? 1 : 0.45)
                .animation(Motion.fadeIn, value: armed)
            }
        }
        .frame(height: 40)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 && session.host != nil }
        .animation(Motion.fadeIn, value: hovering)
        .task(id: session.request?.since) {
            armed = false
            guard session.request != nil else { return }
            try? await Task.sleep(for: .seconds(Motion.decisionArmDelay))
            armed = true
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            ClaudeCrab(size: 18, color: session.state.tint, hopping: session.state == .working)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project.isEmpty ? String(localized: "Claude Code") : session.project)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(session.detail)
                    .font(session.request?.tool == "Bash" ? .system(size: 11.5).monospaced() : .system(size: 11.5))
                    .foregroundStyle(session.state == .waiting ? ClaudeTint.amber
                                                               : Color.dimWhite(0.55, contrast))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if session.request == nil {
                switch session.state {
                case .working:
                    Text(session.startedAt, style: .timer)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.dimWhite(0.55, contrast))
                case .waiting:
                    Text("Needs you")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ClaudeTint.amber)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ClaudeTint.green)
                        .accessibilityLabel("Done")
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Small tabs in the top strip to flip between the music and Claude cards.
struct CardTabs: View {
    @ObservedObject var model: NotchModel
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.cardPages, id: \.self) { kind in
                let selected = model.expandedKind == kind
                let color = selected ? Color.white : Color.dimWhite(0.4, contrast)
                Button { model.expandedKind = kind } label: {
                    Group {
                        if kind == .claude {
                            ClaudeCrab(size: 13, color: selected ? ClaudeTint.clay : color)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(color)
                        }
                    }
                    .frame(width: 24, height: 20)
                    .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(kind == .claude ? Text("Claude") : Text("Now Playing"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(Motion.snappy, value: model.expandedKind)
    }
}

// MARK: - Snap layouts

/// The five snap arrangements. Each exposes its sub-regions as normalized rects
/// (top-left origin, y down) that partition the tile — shared by the tile
/// drawing, the pointer hit-test, and the on-screen zone mapping.
enum LayoutKind: CaseIterable {
    case halves, seventyThirty, thirds, leftPlusStack, quad

    var regions: [CGRect] {
        switch self {
        case .halves:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .seventyThirty:
            return [CGRect(x: 0, y: 0, width: 0.7, height: 1),
                    CGRect(x: 0.7, y: 0, width: 0.3, height: 1)]
        case .thirds:
            return [CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1),
                    CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
                    CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)]
        case .leftPlusStack:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .quad:
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        }
    }
}

/// Fixed geometry of the picker's tile row, shared by the view (to lay out) and
/// the drag monitor (to hit-test the pointer against the exact same rects).
enum PickerMetrics {
    static let tileW: CGFloat = 78
    static let tileH: CGFloat = 54
    static let gap: CGFloat = 16
    static let count = 5
    static let topPad: CGFloat = 18       // content top → caption
    static let captionH: CGFloat = 18
    static let captionGap: CGFloat = 16   // caption → tiles
    /// Distance from the content's top edge to the top of the tile row.
    static var rowTop: CGFloat { topPad + captionH + captionGap }
    static var totalW: CGFloat { tileW * CGFloat(count) + gap * CGFloat(count - 1) }
    /// Left edge of tile `i` measured from the content's left edge.
    static func tileLeft(_ i: Int, contentWidth: CGFloat) -> CGFloat {
        (contentWidth - totalW) / 2 + CGFloat(i) * (tileW + gap)
    }
}

/// The 5-tile layout picker (design A) that drops from the notch while a window
/// is dragged up to it. Laid out at absolute positions from `PickerMetrics` so
/// the monitor's hit-test lines up exactly with what's drawn.
struct SnapPickerView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var shown = false
    private let kinds = LayoutKind.allCases
    var body: some View {
        VStack(spacing: PickerMetrics.captionGap) {
            Text("Drop to arrange window")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dimWhite(0.7, contrast))
                .frame(height: PickerMetrics.captionH)
            HStack(spacing: PickerMetrics.gap) {
                ForEach(kinds.enumerated(), id: \.offset) { i, kind in
                    LayoutTile(kind: kind,
                               activeRegion: model.snapTarget?.tile == i ? model.snapTarget?.region : nil)
                        .frame(width: PickerMetrics.tileW, height: PickerMetrics.tileH)
                        .staggerIn(shown, delay: 0.05 + Double(i) * 0.03, reduceMotion: reduceMotion)
                }
            }
        }
        .padding(.top, PickerMetrics.topPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// A small "aware" pill shown while the window nears the notch but hasn't
/// reached it yet — a downward chevron hints "keep going to open layouts".
/// The glyphs flank the camera housing, like the collapsed pill, so the
/// physical notch never hides them.
struct ArmedPill: View {
    var notchWidth: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: notchWidth)
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .foregroundStyle(Color.dimWhite(0.85, contrast))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One layout icon: flat grey blocks on a dark tile, matching the mock. Blocks
/// are placed from the kind's normalized regions; the region under the pointer
/// (`activeRegion`) lights up blue. (bg #1a1a1d · border #2c2c31 · blocks #3c3f47)
struct LayoutTile: View {
    let kind: LayoutKind
    /// Index of the region under the pointer, or nil when this tile isn't hovered.
    var activeRegion: Int?
    private let block = Color(red: 0.235, green: 0.247, blue: 0.278)
    private let blockHover = Color(red: 0.36, green: 0.55, blue: 0.95)
    private let hoverBlue = Color(red: 0.231, green: 0.510, blue: 0.965)
    private var active: Bool { activeRegion != nil }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let p: CGFloat = 8, g: CGFloat = 5
            let iw = w - p * 2, ih = h - p * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Color(red: 0.11, green: 0.14, blue: 0.22)
                                 : Color(red: 0.102, green: 0.102, blue: 0.114))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(active ? hoverBlue : Color(red: 0.173, green: 0.173, blue: 0.192),
                                          lineWidth: active ? 2 : 1)
                    }
                ForEach(kind.regions.enumerated(), id: \.offset) { idx, r in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(idx == activeRegion ? blockHover.opacity(0.95) : block)
                        .frame(width: max(0, r.width * iw - g), height: max(0, r.height * ih - g))
                        .position(x: p + r.midX * iw, y: p + r.midY * ih)
                }
            }
        }
        .shadow(color: active ? hoverBlue.opacity(0.45) : .clear, radius: 8, y: 2)
        .offset(y: active && !reduceMotion ? -4 : 0)   // lift the hovered tile
        .animation(reduceMotion ? Motion.fadeIn : Motion.tileLift, value: active)
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

extension Color {
    /// White at `opacity` on the always-black island, raised when Increase
    /// Contrast is on so secondary text and glyphs stay legible.
    static func dimWhite(_ opacity: Double, _ contrast: ColorSchemeContrast) -> Color {
        .white.opacity(contrast == .increased ? min(1, opacity + 0.3) : opacity)
    }
}

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

/// Live audio equalizer bars that wave while playing and settle when paused.
/// Under Reduce Motion the bars hold still at their resting height.
struct Equalizer: View {
    var active: Bool
    var height: CGFloat = 14
    var color: Color = Color(red: 1.0, green: 0.62, blue: 0.24)   // warm amber
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .onAppear { animating = active && !reduceMotion }
        .onChange(of: active) { _, playing in animating = playing && !reduceMotion }
        .onChange(of: reduceMotion) { _, reduce in animating = active && !reduce }
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

/// Circular transport button with a hover ring and press feedback. The title
/// is hidden visually but read by VoiceOver.
struct IconButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = .white
    var action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, symbol: String, size: CGFloat = 15, tint: Color = .white,
         action: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
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

struct ActionButton: View {
    var title: LocalizedStringKey
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
