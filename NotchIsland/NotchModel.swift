import SwiftUI
import Combine
import AppKit

/// Which expanded layout the notch shows when it opens up.
enum ExpandedKind: CaseIterable {
    case nowPlaying
    case notification
}

/// What the island is currently showing.
///   • collapsed    — the idle pill (artwork + equalizer + mute indicators)
///   • sideControls — pill grown sideways with tappable mic/speaker buttons
///                    (pointer over the top strip)
///   • expanded     — the full now-playing / notification card
///                    (pointer dropped below the notch, pinned, or an alert)
enum Presentation: Equatable {
    case collapsed
    case sideControls
    case expanded
}

/// Where the pointer sits relative to the notch, set by the controller.
enum HoverZone: Equatable {
    case none     // away
    case strip    // the thin band across the top → side controls
    case drop     // below the notch line → full card
}

/// Shared state for the Notch Island overlay. Drives both the SwiftUI
/// content and the floating panel's size/position.
@MainActor
final class NotchModel: ObservableObject {
    /// Where the pointer sits relative to the notch (set by the controller).
    @Published var hoverZone: HoverZone = .none
    /// Force the notch to stay open regardless of hover (from the menu bar).
    @Published var pinned = false
    /// A notification is presenting itself (auto-dismisses).
    @Published var alertActive = false
    /// Which content to show while expanded.
    @Published var expandedKind: ExpandedKind = .nowPlaying
    /// Media transport state — toggles the play/pause glyph and the bars.
    @Published var isPlaying = false

    /// System speaker (output) and microphone (input) mute state.
    @Published var outputMuted = false
    @Published var micMuted = false

    /// The resolved layout: pin/alert force the full card; otherwise the hover
    /// zone decides (top strip → side controls, below the notch → full card).
    var presentation: Presentation {
        if pinned || alertActive { return .expanded }
        switch hoverZone {
        case .strip: return .sideControls
        case .drop:  return .expanded
        case .none:  return .collapsed
        }
    }

    /// The full card is showing (drives window clearance + big-card geometry).
    var isExpanded: Bool { presentation == .expanded }

    private var dismissTask: Task<Void, Never>?
    private let audio = SystemAudio()
    private let nowPlaying = NowPlayingProvider()

    init() {
        audio.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshAudio() }
        }
        audio.start()
        refreshAudio()

        nowPlaying.onChange = { [weak self] info in
            MainActor.assumeIsolated { self?.applyNowPlaying(info) }
        }
        nowPlaying.start()
    }

    private func refreshAudio() {
        outputMuted = audio.outputMuted()
        micMuted = audio.micMuted()
    }

    func toggleOutputMute() { audio.toggleOutput() }
    func toggleMicMute()    { audio.toggleMic() }

    // MARK: Now Playing controls

    func playPause() {
        isPlaying.toggle()              // optimistic; the app confirms via notification
        nowPlaying.playPause()
    }
    func nextTrack()     { nowPlaying.next() }
    func previousTrack() { nowPlaying.previous() }

    private func applyNowPlaying(_ info: NowPlayingProvider.Info) {
        hasNowPlaying = info.hasTrack
        artwork = info.artwork
        sourceIcon = info.hasTrack ? Self.appIcon(for: info.sourceBundleID) : nil
        // Recompute the accent only when the artwork actually changes.
        if info.artwork !== lastArtworkForColor {
            lastArtworkForColor = info.artwork
            accentColor = info.artwork.flatMap { Self.accent(from: $0) } ?? Self.defaultAccent
        }
        guard info.hasTrack else {
            trackTitle = "ไม่มีเพลงกำลังเล่น"
            trackMeta = "เปิดเพลงใน Music หรือ Spotify"
            isPlaying = false
            progress = 0
            hasProgress = false
            elapsed = "0:00"
            remaining = ""
            artwork = nil
            return
        }
        trackTitle = info.title.isEmpty ? "กำลังเล่น" : info.title
        trackMeta = [info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " — ")
        isPlaying = info.isPlaying
        let duration = info.duration
        let position = duration > 0 ? min(info.position, duration) : info.position
        hasProgress = duration > 0
        progress = duration > 0 ? CGFloat(max(0, min(1, position / duration))) : 0
        elapsed = Self.timeString(position)
        remaining = duration > 0 ? "−" + Self.timeString(max(0, duration - position)) : ""
    }

    /// Real app icon for a bundle id (Music, Spotify, Chrome…), cached so we
    /// don't hit LaunchServices on every track change.
    private static var iconCache: [String: NSImage] = [:]
    private static func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    private static func timeString(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Pull a vivid accent color from an image: downsample, then pick the most
    /// saturated/bright pixel (ignoring near-black/white), and punch it up a bit.
    private static func accent(from image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }

        let n = 12
        var data = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        var best: (score: CGFloat, h: CGFloat, s: CGFloat, b: CGFloat)?
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = CGFloat(data[i]) / 255, g = CGFloat(data[i + 1]) / 255, bl = CGFloat(data[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
            NSColor(red: r, green: g, blue: bl, alpha: 1).getHue(&h, saturation: &s, brightness: &br, alpha: nil)
            if br < 0.15 || br > 0.96 { continue }        // skip near-black / near-white
            let score = s * br
            if best == nil || score > best!.score { best = (score, h, s, br) }
        }
        guard let pick = best else { return nil }
        return Color(hue: pick.h,
                     saturation: min(1, max(0.55, pick.s)),
                     brightness: min(0.95, max(0.7, pick.b)))
    }

    /// Pop the notification in and let it auto-dismiss after a few seconds
    /// (unless the pointer is over it, which keeps it open via the hover zone).
    func presentNotification(for seconds: Double = 4) {
        expandedKind = .notification
        alertActive = true
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.alertActive = false
        }
    }

    /// Physical width/height of the display's notch (0 if the screen has none).
    /// Set by the controller so the collapsed pill can match the real notch.
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
    /// Clearance to keep at the top (physical notch / menu-bar height) on the
    /// screen the island currently lives on. Updated as it follows the cursor.
    @Published var topInset: CGFloat = 0

    /// Slot on each side of the notch for the artwork / equalizer.
    private let sideModule: CGFloat = 44
    /// Width of one trailing controls block (the mic + speaker buttons). Added
    /// on the right *and* mirrored as blank space on the left, so the notch gap
    /// stays centered when the pill grows into `.sideControls`.
    let controlsBlock: CGFloat = 60

    // Sizes are given in points, matching the "แบบ A" spec (1pt = 1px).
    var collapsedSize: CGSize {
        // Wide enough that artwork and bars sit clear of the notch edges, and
        // as tall as the physical notch so they fill it (falls back to 32pt).
        let base = notchWidth > 0 ? notchWidth + sideModule * 2 : 200
        // Extra room to append a mute icon on the trailing side (symmetric, so
        // the pill stays centered on the notch). slash glyphs are wide.
        let extra: CGFloat = (micMuted ? 28 : 0) + (outputMuted ? 28 : 0)
        let h = notchHeight > 0 ? notchHeight : 32
        return CGSize(width: base + extra, height: h)
    }
    /// The pill grown sideways to fit tappable mic/speaker buttons. Same height
    /// as the collapsed pill (it stays in the top strip, never drops down);
    /// wider by a controls block on each side to keep the notch gap centered.
    var sideControlsSize: CGSize {
        let base = notchWidth > 0 ? notchWidth + sideModule * 2 : 200
        let h = notchHeight > 0 ? notchHeight : 32
        return CGSize(width: base + controlsBlock * 2, height: h)
    }
    let expandedSize = CGSize(width: 480, height: 170)

    var contentSize: CGSize {
        switch presentation {
        case .collapsed:    return collapsedSize
        case .sideControls: return sideControlsSize
        case .expanded:     return expandedSize
        }
    }

    // MARK: Now Playing (live)

    @Published var hasNowPlaying = false
    @Published var trackTitle = "ไม่มีเพลงกำลังเล่น"
    @Published var trackMeta  = "เปิดเพลงใน Music หรือ Spotify"
    @Published var elapsed    = "0:00"
    @Published var remaining  = ""
    @Published var progress: CGFloat = 0
    /// True only when the source reports a real duration (so the bar can move).
    @Published var hasProgress = false
    @Published var artwork: NSImage?
    /// Icon of the app the track plays from (Music/Spotify/Chrome…), for a
    /// small source badge on the artwork. Nil when nothing is playing.
    @Published var sourceIcon: NSImage?
    /// Accent color pulled from the artwork (falls back to warm amber).
    @Published var accentColor = NotchModel.defaultAccent
    static let defaultAccent = Color(red: 1.0, green: 0.62, blue: 0.24)
    private var lastArtworkForColor: NSImage?

    // MARK: Notification (sample — Phase 3)
    let notifApp   = "ปฏิทิน"
    let notifWhen  = "เมื่อสักครู่"
    let notifLine1 = "ประชุมออกแบบรายสัปดาห์ เริ่มในอีก 10 นาที"
    let notifLine2 = "ห้อง Studio B · กับ Nan, Pete และอีก 4 คน"
}
