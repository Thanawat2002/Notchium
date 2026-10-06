import ServiceManagement
import AppKit

/// Start the app automatically at login, via the modern `SMAppService` (macOS
/// 13+) — the app registers itself, no separate login-item helper bundle.
enum LaunchAtLogin {
    /// True only when the login item is actually enabled (not merely pending
    /// the user's approval in System Settings).
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // A fresh registration can land in "requires approval"; send the
                // user to the Login Items list to flip it on.
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: \(enabled ? "register" : "unregister") failed — \(error)")
        }
    }
}
