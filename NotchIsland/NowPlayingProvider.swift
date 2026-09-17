import Foundation
import AppKit

/// Reads and controls "now playing" from the apps that expose it on modern
/// macOS, since the system-wide MediaRemote now-playing API is no longer
/// available to third parties:
///   • Music.app / Spotify — metadata via distributed notifications, controls,
///     position and artwork via AppleScript.
///   • Chromium browsers (Chrome, Arc, Brave, Edge) — metadata, position,
///     artwork and play/pause via injected JavaScript (`navigator.mediaSession`
///     + the page's <video>/<audio>). Needs "Allow JavaScript from Apple Events".
///   • Dia (blocks JS-from-Apple-Events) — title + YouTube thumbnail via the
///     tab's URL only.
final class NowPlayingProvider {
    struct Info {
        var title = ""
        var artist = ""
        var album = ""
        var isPlaying = false
        var duration: Double = 0     // seconds
        var position: Double = 0     // seconds
        var hasTrack = false
        var artwork: NSImage?
        /// Bundle id of the app the track is playing from (Music/Spotify/browser).
        var sourceBundleID = ""
    }

    /// Delivered on the main queue.
    var onChange: ((Info) -> Void)?

    private(set) var info = Info()
    private var activeBundleID: String?
    private var pollTimer: Timer?
    private let scriptQueue = DispatchQueue(label: "notchisland.applescript")

    // Artwork resolution + cache.
    private var currentArtKey: String?
    private var currentArt: NSImage?
    private var imageCache: [String: NSImage] = [:]

    private let music = "com.apple.Music"
    private let spotify = "com.spotify.client"
    private let browsers = ["com.google.Chrome", "com.brave.Browser",
                            "company.thebrowser.Browser", "company.thebrowser.dia",
                            "com.microsoft.edgemac"]
    private let mediaHosts = ["youtube.com/watch", "music.youtube.com",
                              "soundcloud.com", "open.spotify.com", "music.apple.com"]

    // One-expression scripts, single-quotes only so they embed cleanly in the
    // double-quoted AppleScript argument. Fields joined with ||| (rare in titles).
    private let readJS = "(function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;var v=document.querySelector('video,audio');if(!m&&!v)return '';var t=m&&m.title?m.title:(document.title||'');var a=m&&m.artist?m.artist:'';var al=m&&m.album?m.album:'';var p=v?(v.paused?'0':'1'):'0';var c=v?v.currentTime:0;var d=v&&isFinite(v.duration)?v.duration:0;var ar='';if(m&&m.artwork&&m.artwork.length){ar=m.artwork[m.artwork.length-1].src||''}return [t,a,al,p,c,d,ar].join('|||');})()"
    private let playPauseJS = "(function(){var v=document.querySelector('video,audio');if(v){if(v.paused){v.play()}else{v.pause()}return '1'}return '0'})()"

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)

        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        pollTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Controls

    func playPause() {
        if isBrowser(activeBundleID) {
            runScript(browserScript(playPauseJS, bundle: activeBundleID!)) { [weak self] _ in
                self?.scanBrowsers()
            }
        } else {
            control("playpause")
        }
    }

    func next()     { if !isBrowser(activeBundleID) { control("next track") } }
    func previous() { if !isBrowser(activeBundleID) { control("previous track") } }

    private func control(_ command: String) {
        let bundle = activeBundleID ?? runningPlayer() ?? music
        runScript("tell application id \"\(bundle)\" to \(command)") { [weak self] _ in
            self?.pollPositionNative(bundle)
        }
    }

    // MARK: Native notifications

    @objc private func musicChanged(_ note: Notification) {
        handle(note.userInfo ?? [:], bundle: music)
    }

    @objc private func spotifyChanged(_ note: Notification) {
        handle(note.userInfo ?? [:], bundle: spotify)
    }

    private func handle(_ userInfo: [AnyHashable: Any], bundle: String) {
        let state = userInfo["Player State"] as? String ?? ""
        let playing = state == "Playing"
        let title = userInfo["Name"] as? String ?? ""
        let stopped = state == "Stopped" || (title.isEmpty && !playing)

        var new = Info()
        new.title = title
        new.artist = userInfo["Artist"] as? String ?? ""
        new.album = userInfo["Album"] as? String ?? ""
        new.isPlaying = playing
        let rawMs = (userInfo["Total Time"] as? Double) ?? (userInfo["Duration"] as? Double) ?? 0
        new.duration = rawMs / 1000
        new.position = info.position
        new.hasTrack = !stopped && !title.isEmpty
        new.sourceBundleID = bundle

        if playing { activeBundleID = bundle }

        if new.hasTrack {
            let key = "native:\(bundle):\(new.title)|\(new.artist)"
            publish(new, artKey: key) { [weak self] done in
                self?.fetchNativeArtwork(bundle, done)
            }
        } else {
            publish(new, artKey: nil, fetch: nil)
        }
        pollPositionNative(bundle)
    }

    // MARK: Poll loop

    private func tick() {
        if let b = activeBundleID, isNative(b), info.isPlaying {
            pollPositionNative(b)
            return
        }
        scanBrowsers()
    }

    private func pollPositionNative(_ bundle: String) {
        guard isNative(bundle), info.isPlaying else { return }
        runScript("tell application id \"\(bundle)\" to get player position") { [weak self] result in
            guard let self, let result, let pos = Double(result) else { return }
            self.info.position = pos
            self.emit()
        }
    }

    // MARK: Browser scanning

    private func scanBrowsers() {
        let running = runningBundles()
        guard let target = browsers.first(where: { running.contains($0) }) else { return }

        runScript(browserScript(readJS, bundle: target)) { [weak self] result in
            guard let self else { return }
            if let result, !result.isEmpty {
                let f = result.components(separatedBy: "|||")
                guard f.count >= 6, !f[0].isEmpty else { return }
                var new = Info()
                new.title = f[0]
                new.artist = f[1]
                new.album = f[2]
                new.isPlaying = f[3] == "1"
                new.position = Double(f[4]) ?? 0
                new.duration = Double(f[5]) ?? 0
                new.hasTrack = true
                new.sourceBundleID = target
                let art = f.count >= 7 ? f[6] : ""

                if new.isPlaying || self.activeBundleID == nil || self.isBrowser(self.activeBundleID) {
                    self.activeBundleID = target
                    let key = art.isEmpty ? "browser:\(new.title)" : art
                    self.publish(new, artKey: key) { done in
                        if art.isEmpty { done(nil) } else { self.loadImage(art, completion: done) }
                    }
                }
                return
            }
            self.browserMediaTabFallback(target)
        }
    }

    /// Title-only fallback across all tabs for known media hosts (used by Dia).
    private func browserMediaTabFallback(_ bundle: String) {
        let condition = mediaHosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let source = """
        tell application id "\(bundle)"
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if \(condition) then return u & "|||" & (title of t)
                    end repeat
                end repeat
            end try
            return ""
        end tell
        """
        runScript(source) { [weak self] result in
            guard let self else { return }
            guard let result, !result.isEmpty else {
                if self.isBrowser(self.activeBundleID) && self.info.hasTrack {
                    self.publish(Info(), artKey: nil, fetch: nil)
                }
                return
            }
            let parts = result.components(separatedBy: "|||")
            guard parts.count >= 2 else { return }
            var new = Info()
            new.title = self.cleanTitle(parts[1])
            new.isPlaying = true          // play state unknown; assume active
            new.hasTrack = !new.title.isEmpty
            new.sourceBundleID = bundle
            self.activeBundleID = bundle

            let url = parts[0]
            if let thumb = self.youTubeThumbnail(from: url) {
                self.publish(new, artKey: thumb) { done in self.loadImage(thumb, completion: done) }
            } else {
                self.publish(new, artKey: nil, fetch: nil)
            }
        }
    }

    private func browserScript(_ js: String, bundle: String) -> String {
        """
        tell application id "\(bundle)"
            if (count of windows) is 0 then return ""
            try
                return execute active tab of window 1 javascript "\(js)"
            on error
                return ""
            end try
        end tell
        """
    }

    // MARK: Initial native fetch

    private func refresh() {
        let running = runningBundles()
        for bundle in [spotify, music] where running.contains(bundle) {
            fetchNative(bundle)
        }
    }

    private func fetchNative(_ bundle: String) {
        let ms = bundle == spotify
        let source = """
        tell application id "\(bundle)"
            if it is not running then return ""
            try
                if player state is stopped then return ""
            end try
            set t to ""
            set a to ""
            set al to ""
            set d to 0
            set p to 0
            try
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
            end try
            try
                set p to player position
            end try
            set st to player state as string
            return t & "|||" & a & "|||" & al & "|||" & (d as string) & "|||" & (p as string) & "|||" & st
        end tell
        """
        runScript(source) { [weak self] result in
            guard let self, let result, !result.isEmpty else { return }
            let f = result.components(separatedBy: "|||")
            guard f.count >= 6 else { return }
            var new = Info()
            new.title = f[0]
            new.artist = f[1]
            new.album = f[2]
            let d = Double(f[3]) ?? 0
            new.duration = ms ? d / 1000 : d
            new.position = Double(f[4]) ?? 0
            new.isPlaying = f[5] == "playing"
            new.hasTrack = !f[0].isEmpty
            new.sourceBundleID = bundle
            guard new.hasTrack, new.isPlaying || !self.info.hasTrack else { return }
            if new.isPlaying { self.activeBundleID = bundle }
            let key = "native:\(bundle):\(new.title)|\(new.artist)"
            self.publish(new, artKey: key) { done in self.fetchNativeArtwork(bundle, done) }
        }
    }

    // MARK: Artwork

    private func fetchNativeArtwork(_ bundle: String, _ completion: @escaping (NSImage?) -> Void) {
        if bundle == spotify {
            runScript("tell application id \"\(spotify)\" to get artwork url of current track") { [weak self] urlStr in
                guard let self, let urlStr, !urlStr.isEmpty else { completion(nil); return }
                self.loadImage(urlStr, completion: completion)
            }
        } else {
            runDescriptor("tell application id \"\(music)\" to get data of artwork 1 of current track") { desc in
                guard let bytes = desc?.data else { completion(nil); return }
                completion(NSImage(data: bytes))
            }
        }
    }

    private func youTubeThumbnail(from url: String) -> String? {
        guard url.contains("youtube.com") || url.contains("youtu.be") else { return nil }
        if let comps = URLComponents(string: url),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return "https://img.youtube.com/vi/\(v)/hqdefault.jpg"
        }
        return nil
    }

    private func loadImage(_ urlString: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = imageCache[urlString] { completion(cached); return }
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                if let image { self?.imageCache[urlString] = image }
                completion(image)
            }
        }.resume()
    }

    // MARK: Publish

    /// Set `info` to `new`, resolve artwork (cached by key), and emit — twice if
    /// artwork must be fetched (once immediately, once when the image arrives).
    private func publish(_ new: Info, artKey: String?,
                         fetch: ((@escaping (NSImage?) -> Void) -> Void)?) {
        var updated = new
        if let artKey, artKey == currentArtKey {
            updated.artwork = currentArt
            info = updated
            emit()
            return
        }
        guard let artKey, let fetch else {
            currentArtKey = nil
            currentArt = nil
            info = updated
            emit()
            return
        }
        currentArtKey = artKey
        currentArt = nil
        info = updated
        emit()
        fetch { [weak self] image in
            guard let self, self.currentArtKey == artKey else { return }
            self.currentArt = image
            self.info.artwork = image
            self.emit()
        }
    }

    // MARK: Plumbing

    private func isNative(_ bundle: String?) -> Bool { bundle == music || bundle == spotify }
    private func isBrowser(_ bundle: String?) -> Bool { bundle.map { browsers.contains($0) } ?? false }

    private func runningBundles() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    private func runningPlayer() -> String? {
        let running = runningBundles()
        return [spotify, music].first(where: { running.contains($0) })
    }

    private func cleanTitle(_ raw: String) -> String {
        var t = raw
        for suffix in [" - YouTube", " • SoundCloud", " | Spotify", " - Spotify"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        if let range = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func runScript(_ source: String, completion: @escaping (String?) -> Void) {
        scriptQueue.async {
            var error: NSDictionary?
            let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let value = error == nil ? descriptor?.stringValue : nil
            DispatchQueue.main.async { completion(value) }
        }
    }

    private func runDescriptor(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        scriptQueue.async {
            var error: NSDictionary?
            let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.async { completion(error == nil ? descriptor : nil) }
        }
    }

    private func emit() {
        let snapshot = info
        onChange?(snapshot)
    }
}
