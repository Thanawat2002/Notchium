import SwiftUI
import Carbon.HIToolbox

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Notch Island", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent(model: appDelegate.model,
                        onEnableSnap: { appDelegate.enableSnapLayouts() })
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    private var controller: NotchController?
    private var micHotKey: HotKey?
    private var snap: WindowSnapController?
    private var snapPreview: SnapPreviewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon
        let controller = NotchController(model: model)
        controller.show()
        self.controller = controller

        // Global shortcut ⌃⌥⌘M toggles the microphone mute.
        micHotKey = HotKey(keyCode: UInt32(kVK_ANSI_M),
                           modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            MainActor.assumeIsolated { self?.model.toggleMicMute() }
        }

        // Snap layouts: starts watching only once Accessibility is granted.
        snap = WindowSnapController(model: model)
        snap?.start()
        snapPreview = SnapPreviewController(model: model)   // on-screen zone preview
    }

    /// Prompt for Accessibility, then keep polling until it's granted so the
    /// snap monitor can start without a relaunch.
    func enableSnapLayouts() {
        Accessibility.request()
        guard !Accessibility.isTrusted else { snap?.start(); return }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard Accessibility.isTrusted else { return }
                self?.snap?.start()
                timer.invalidate()
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: NotchModel
    var onEnableSnap: () -> Void = {}

    var body: some View {
        Button("Now Playing") {
            model.expandedKind = .nowPlaying
            model.pinned = true
        }
        Button("Show Notification") {
            model.presentNotification()
        }
        Divider()
        if Accessibility.isTrusted {
            Text("Window Snapping: On")
        } else {
            Button("Enable Window Snapping…", action: onEnableSnap)
        }
        Divider()
        Button(model.outputMuted ? "Unmute Speaker" : "Mute Speaker") {
            model.toggleOutputMute()
        }
        Button(model.micMuted ? "Unmute Microphone  (⌃⌥⌘M)" : "Mute Microphone  (⌃⌥⌘M)") {
            model.toggleMicMute()
        }
        Divider()
        Toggle("Keep Expanded", isOn: $model.pinned)
        Divider()
        Button("Quit Notch Island") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
