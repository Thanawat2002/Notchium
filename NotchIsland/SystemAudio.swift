import CoreAudio
import Foundation

/// Thin wrapper over CoreAudio to read and toggle the mute state of the
/// default output (speaker) and input (microphone) devices, and to notify
/// when either changes — from us or from anywhere else in the system.
final class SystemAudio {
    /// Called on the main queue whenever mute state or the default device changes.
    var onChange: (() -> Void)?

    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var savedVolume: [AudioObjectPropertyScope: Float32] = [:]

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func start() {
        outputDevice = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        inputDevice  = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        addDefaultDeviceListeners()
        addMuteListeners()
    }

    // MARK: Public state

    func outputMuted() -> Bool { muted(outputDevice, scope: kAudioObjectPropertyScopeOutput) }
    func micMuted() -> Bool    { muted(inputDevice,  scope: kAudioObjectPropertyScopeInput) }

    func toggleOutput() {
        setMuted(!outputMuted(), device: outputDevice, scope: kAudioObjectPropertyScopeOutput)
    }
    func toggleMic() {
        setMuted(!micMuted(), device: inputDevice, scope: kAudioObjectPropertyScopeInput)
    }

    // MARK: Device resolution

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &device)
        return device
    }

    // MARK: Mute

    private func muteAddress(_ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func muted(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var addr = muteAddress(scope)
        if AudioObjectHasProperty(device, &addr) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        // Devices without a mute switch: treat volume 0 as muted.
        if let v = volumeScalar(device, scope: scope) { return v <= 0.0001 }
        return false
    }

    private func setMuted(_ mute: Bool, device: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = muteAddress(scope)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &addr),
           AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
            var value: UInt32 = mute ? 1 : 0
            AudioObjectSetPropertyData(device, &addr, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            // Fallback for devices without a mute switch: drop volume to 0.
            if mute {
                savedVolume[scope] = volumeScalar(device, scope: scope) ?? 0.5
                setVolumeScalar(0, device: device, scope: scope)
            } else {
                setVolumeScalar(savedVolume[scope] ?? 0.5, device: device, scope: scope)
            }
        }
        onChange?()
    }

    // MARK: Volume fallback (main element, then channels 1/2)

    private func volumeAddress(_ scope: AudioObjectPropertyScope,
                               element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element)
    }

    private func volumeScalar(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var addr = volumeAddress(scope, element: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private func setVolumeScalar(_ value: Float32, device: AudioObjectID, scope: AudioObjectPropertyScope) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var addr = volumeAddress(scope, element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
            else { continue }
            var v = value
            AudioObjectSetPropertyData(device, &addr, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    // MARK: Listeners

    private func addMuteListeners() {
        addListener(outputDevice, muteAddress(kAudioObjectPropertyScopeOutput))
        addListener(inputDevice,  muteAddress(kAudioObjectPropertyScopeInput))
    }

    private func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        guard object != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = address
        AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onChange?()
        }
    }

    private func addDefaultDeviceListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
                guard let self else { return }
                self.outputDevice = self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
                self.inputDevice  = self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
                self.addMuteListeners()
                self.onChange?()
            }
        }
    }
}
