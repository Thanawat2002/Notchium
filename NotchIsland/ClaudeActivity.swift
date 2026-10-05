import AppKit
import Network

/// One Claude Code session as seen through its hooks.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Int, Comparable {
        case waiting   // blocked on the user (permission prompt, question)
        case working   // prompt submitted, running tools / thinking
        case done      // Stop fired — finished its turn
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    var project: String
    var state: State
    /// What it's doing right now ("Editing NotchView.swift", the prompt text…).
    var detail: String
    /// When the current turn started — drives the elapsed timer.
    var startedAt: Date
    var updatedAt: Date
    /// Where the session runs, so tapping its row can switch there.
    var host: ClaudeHost?
    /// A permission prompt held for an answer from the notch.
    var request: PermissionAsk?
}

/// A tool call waiting on Allow / Deny.
struct PermissionAsk: Equatable {
    let tool: String
    /// What it wants to do, in full ("npm install", "Edit NotchView.swift").
    let summary: String
    let since: Date
}

/// Live status of Claude Code sessions, fed by Claude Code hooks.
///
/// Each hook pipes its JSON payload to a tiny HTTP listener on localhost:
///
///     curl -s --max-time 1 -H 'Expect:' -H "X-Claude-PID: $PPID" \
///          --data-binary @- http://127.0.0.1:47821/claude
///
/// (`$PPID` is the `claude` process that ran the hook — used to find the
/// terminal app hosting the session.)
///
/// so the app needs no permissions, and when it isn't running the hook just
/// fails silently. `ClaudeHooks.install()` writes those hooks into
/// `~/.claude/settings.json`.
///
/// `PermissionRequest` is the exception: Claude Code waits for that hook
/// before showing its own prompt, so the listener holds the connection until
/// the user taps Allow / Deny in the notch and answers with the decision. An
/// empty answer (timeout, "open in terminal", app not running) makes Claude
/// Code fall back to its normal prompt.
@MainActor
final class ClaudeActivity {
    nonisolated static let port: UInt16 = 47821

    /// Sessions changed (sorted: waiting → working → done, newest first).
    var onChange: (@MainActor ([ClaudeSession]) -> Void)?
    /// A session just started waiting on the user.
    var onNeedsAttention: (@MainActor (ClaudeSession) -> Void)?
    /// A session just finished its turn.
    var onFinished: (@MainActor (ClaudeSession) -> Void)?

    private var sessions: [String: ClaudeSession] = [:]
    /// Held `PermissionRequest` connections, by session.
    private var held: [String: (conn: NWConnection, timeout: Task<Void, Never>)] = [:]
    private var listener: NWListener?
    private var pruneTimer: Timer?

    /// Finished sessions linger in the card this long, then drop off.
    private let doneTTL: TimeInterval = 5 * 60
    /// A session with no events this long is assumed gone (terminal closed
    /// without SessionEnd). Generous, since a single build can run for minutes.
    private let staleTTL: TimeInterval = 30 * 60
    /// How long a permission prompt waits on the notch before going back to
    /// the terminal. Below the hook's own `--max-time`.
    nonisolated static let decisionTimeout: TimeInterval = 110

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — nothing off this Mac can reach it.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    // MARK: HTTP (just enough to read one POST body)

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let chunk { buffer.append(chunk) }
                if let (head, body) = Self.request(from: buffer) {
                    let pid = Self.header("x-claude-pid", in: head).flatMap { pid_t($0) }
                    if self?.handle(body, pid: pid, conn: conn) != true { Self.reply(conn) }
                } else if isComplete || error != nil || buffer.count > 1_000_000 {
                    conn.cancel()
                } else {
                    self?.receive(on: conn, buffer: buffer)
                }
            }
        }
    }

    /// Headers + body once headers and `Content-Length` bytes have arrived.
    private static func request(from data: Data) -> (head: String, body: Data)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let length = header("content-length", in: head).flatMap { Int($0) } ?? 0
        let body = data[split.upperBound...]
        return body.count >= length ? (head, Data(body.prefix(length))) : nil
    }

    private static func header(_ name: String, in head: String) -> String? {
        head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix(name + ":") }
            .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
    }

    /// Answer and close. No body → the hook prints nothing.
    private static func reply(_ conn: NWConnection, body: Data? = nil) {
        var response: Data
        if let body {
            response = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
            response.append(body)
        } else {
            response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
        }
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Permission decisions

    /// Answer a held permission prompt: allow, deny, or nil to hand it back
    /// to the terminal's own prompt.
    func answer(sessionID id: String, allow: Bool?) {
        guard let (conn, timeout) = held.removeValue(forKey: id) else { return }
        timeout.cancel()
        if let allow {
            let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                 "decision": ["behavior": allow ? "allow" : "deny"]]]
            Self.reply(conn, body: try? JSONSerialization.data(withJSONObject: output))
        } else {
            Self.reply(conn)
        }
        guard var session = sessions[id] else { return }
        session.request = nil
        if let allow {
            session.state = .working
            session.detail = allow ? String(localized: "Thinking…") : String(localized: "Denied")
        }
        session.updatedAt = .now
        sessions[id] = session
        publish()
    }

    private func hold(_ conn: NWConnection, for id: String) {
        answer(sessionID: id, allow: nil)       // a newer prompt supersedes an older one
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.decisionTimeout))
            guard !Task.isCancelled else { return }
            self?.answer(sessionID: id, allow: nil)
        }
        held[id] = (conn, timeout)
        // If Claude gives up on the hook (Esc, its own timeout) curl goes away —
        // stop offering buttons that can no longer do anything.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            MainActor.assumeIsolated { self?.dropHeld(id, conn) }
        }
    }

    private func dropHeld(_ id: String, _ conn: NWConnection) {
        guard let entry = held[id], entry.conn === conn else { return }
        entry.timeout.cancel()
        held[id] = nil
        conn.cancel()
        sessions[id]?.request = nil
        publish()
    }

    // MARK: Events

    /// Returns true when it kept `conn` open to answer later (a held prompt).
    @discardableResult
    private func handle(_ body: Data, pid: pid_t?, conn: NWConnection) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["session_id"] as? String,
              let event = json["hook_event_name"] as? String else { return false }
        let now = Date.now
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        var session = sessions[id] ?? ClaudeSession(
            id: id, project: project, state: .working,
            detail: String(localized: "Thinking…"), startedAt: now, updatedAt: now)
        if !project.isEmpty { session.project = project }
        // Resolve once per claude process, while it's alive to be walked.
        if let pid, session.host?.claudePID != pid { session.host = ClaudeHost.resolve(claudePID: pid) }
        let previous = sessions[id]?.state
        session.updatedAt = now
        var holding = false

        // While a prompt is held, other tool events (parallel calls) mustn't
        // flip the session out of "waiting" and hide its buttons.
        if held[id] != nil, ["PreToolUse", "PostToolUse", "Notification"].contains(event) {
            sessions[id] = session
            return false
        }

        switch event {
        case "PermissionRequest":
            // If you're already looking at the terminal, let its own prompt
            // show right away instead of holding it here.
            if let host = session.host,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == host.appPID { return false }
            let tool = json["tool_name"] as? String ?? ""
            let summary = Self.summarize(tool: tool, input: json["tool_input"] as? [String: Any] ?? [:])
            session.state = .waiting
            session.detail = summary
            session.request = PermissionAsk(tool: tool, summary: summary, since: now)
            hold(conn, for: id)
            holding = true
        case "UserPromptSubmit":
            answer(sessionID: id, allow: nil)
            session.request = nil
            session.state = .working
            session.startedAt = now
            session.detail = String(localized: "Thinking…")
        case "PreToolUse":
            if session.state == .done { session.startedAt = now }
            session.state = .working
            session.detail = Self.describe(tool: json["tool_name"] as? String ?? "",
                                           input: json["tool_input"] as? [String: Any] ?? [:])
        case "PostToolUse":
            // Also how we learn a permission prompt was answered.
            if session.state == .waiting { session.detail = String(localized: "Thinking…") }
            session.state = .working
        case "Notification":
            // "Waiting for your input" fires a minute after every finished turn —
            // that's not news, the session is already shown as done.
            if json["notification_type"] as? String == "idle_prompt" { return false }
            session.state = .waiting
            session.detail = json["message"] as? String ?? String(localized: "Needs your attention")
        case "Stop":
            answer(sessionID: id, allow: nil)
            session.request = nil
            session.state = .done
            session.detail = String(localized: "Done")
        case "SessionEnd":
            answer(sessionID: id, allow: nil)
            sessions[id] = nil
            publish()
            return false
        default:
            return false
        }

        sessions[id] = session
        publish()
        if session.state != previous {
            if session.state == .waiting { onNeedsAttention?(session) }
            if session.state == .done { onFinished?(session) }
        }
        return holding
    }

    /// What a permission prompt asks for, in full, for the Allow / Deny row.
    private static func summarize(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch tool {
        case "Bash":
            let command = (input["command"] as? String ?? "")
                .split(whereSeparator: \.isNewline).joined(separator: " ")
            return command.isEmpty ? String(localized: "Run a command") : command
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return String(localized: "Edit \(file)")
        case "WebFetch":
            return input["url"] as? String ?? String(localized: "Fetch a web page")
        default:
            return String(localized: "Use \(tool)")
        }
    }

    /// Short, human summary of a tool call for the status line.
    private static func describe(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return String(localized: "Editing \(file)")
        case "Read":
            return String(localized: "Reading \(file)")
        case "Bash":
            let what = input["description"] as? String ?? input["command"] as? String ?? ""
            return what.isEmpty ? String(localized: "Running a command") : what
        case "Grep", "Glob":
            return String(localized: "Searching the code")
        case "WebFetch", "WebSearch":
            return String(localized: "Browsing the web")
        case "Task", "Agent":
            return String(localized: "Running an agent")
        default:
            return String(localized: "Using \(tool)")
        }
    }

    private func prune() {
        let now = Date.now
        let before = sessions.count
        sessions = sessions.filter { _, s in
            let age = now.timeIntervalSince(s.updatedAt)
            return s.state == .done ? age < doneTTL : age < staleTTL
        }
        if sessions.count != before { publish() }
    }

    private func publish() {
        onChange?(sessions.values.sorted {
            $0.state != $1.state ? $0.state < $1.state : $0.updatedAt > $1.updatedAt
        })
    }
}

/// Installs the hooks that report to `ClaudeActivity` into Claude Code's user
/// settings (`~/.claude/settings.json`), merging with whatever is there.
enum ClaudeHooks {
    /// `Expect:` stops curl waiting for a "100 Continue" on large payloads
    /// (an Edit's tool_input), which the listener never sends.
    static let command = "curl -s --max-time 1 -H 'Expect:' -H \"X-Claude-PID: $PPID\" --data-binary @- "
        + "\(endpoint) >/dev/null 2>&1 || true"
    /// Waits for the notch's answer and prints it for Claude Code (prints
    /// nothing on failure → Claude Code shows its normal prompt).
    static let decisionCommand = "curl -s --max-time \(Int(ClaudeActivity.decisionTimeout) + 10) -H 'Expect:' "
        + "-H \"X-Claude-PID: $PPID\" --data-binary @- \(endpoint) 2>/dev/null || true"
    /// Identifies our hooks (current or older versions of the command).
    private static let endpoint = "http://127.0.0.1:\(ClaudeActivity.port)/claude"
    private static let events = ["UserPromptSubmit": command, "PreToolUse": command,
                                 "PostToolUse": command, "Notification": command,
                                 "Stop": command, "SessionEnd": command,
                                 "PermissionRequest": decisionCommand]
    private static let toolEvents: Set = ["PreToolUse", "PostToolUse", "PermissionRequest"]
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Every event carries its current command. (Parsed, not a text search —
    /// the command's quotes come back escaped in the file.)
    static func isInstalled(at url: URL = settingsURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event, command in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    /// Adds our hook to each event, replacing older versions of it. Keeps a
    /// backup of the original file next to it.
    static func install(at settingsURL: URL = settingsURL) throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)   // don't clobber a file we can't read
            }
            settings = parsed
            let backup = settingsURL.appendingPathExtension("notchisland-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, command) in events {
            // Drop our earlier hooks (and any group left empty), keep the rest.
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter { !(($0["command"] as? String)?.contains(endpoint) ?? false) }
                if kept.isEmpty { return nil }
                var group = group
                group["hooks"] = kept
                return group
            }
            var hook: [String: Any] = ["type": "command", "command": command]
            // Outlast curl's own limit so the hook is never killed mid-answer.
            if command == decisionCommand { hook["timeout"] = Int(ClaudeActivity.decisionTimeout) + 20 }
            var group: [String: Any] = ["hooks": [hook]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

/// The app a Claude Code session runs in (Terminal, iTerm, VS Code, the Claude
/// app…) plus its tty, found by walking up the process tree from `claude`.
struct ClaudeHost: Equatable {
    let claudePID: pid_t
    let appPID: pid_t
    let bundleID: String
    /// e.g. "/dev/ttys003" — lets Terminal / iTerm jump to the exact tab.
    let tty: String?

    static func resolve(claudePID: pid_t) -> ClaudeHost? {
        let tty = process(claudePID).flatMap { info -> String? in
            let dev = info.kp_eproc.e_tdev     // -1 (NODEV) when there is no tty
            guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
            return "/dev/" + String(cString: name)
        }
        // Climb until a regular (Dock) app: shells, pty hosts and helpers
        // in between aren't. A bounded walk guards against odd trees.
        var pid = claudePID
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular, let bundleID = app.bundleIdentifier {
                return ClaudeHost(claudePID: claudePID, appPID: pid, bundleID: bundleID, tty: tty)
            }
            guard let parent = process(pid)?.kp_eproc.e_ppid, parent > 1 else { return nil }
            pid = parent
        }
        return nil
    }

    private static func process(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static let scriptQueue = DispatchQueue(label: "notchisland.claude-focus")

    /// Bring the session's app forward — and, for Terminal / iTerm, the tab
    /// running it.
    func focus() {
        if let tty, let script = Self.selectTabScript(bundleID: bundleID, tty: tty) {
            // AppleScript also activates; it blocks (first run asks for
            // Automation permission), so keep it off the main thread.
            Self.scriptQueue.async {
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if error != nil { DispatchQueue.main.async { activate() } }
            }
        } else {
            activate()
        }
    }

    /// Plain activation. Goes through NSWorkspace: we're a background app, and
    /// `NSRunningApplication.activate()` from one is often ignored.
    private func activate() {
        guard let url = NSRunningApplication(processIdentifier: appPID)?.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func selectTabScript(bundleID: String, tty: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return nil
        }
    }
}
