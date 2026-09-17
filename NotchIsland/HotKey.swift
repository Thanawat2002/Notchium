import Carbon.HIToolbox
import AppKit

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey — fires even
/// when the app isn't focused, and needs no Accessibility/Input-Monitoring grant.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private let hotKeyID = EventHotKeyID(signature: 0x4E4F5443 /* 'NOTC' */, id: 1)

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_M`); `modifiers` are Carbon
    /// masks (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        installHandler()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            me.action()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
