import AudioToolbox
import Combine
import CoreAudio

/// The default output device's mute and volume, read through CoreAudio
/// directly since there is no higher-level framework for either on macOS.
enum AudioOutput {
    static func defaultDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func isMuted() -> Bool? {
        guard let device = defaultDeviceID() else { return nil }
        var address = outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ muted: Bool) throws {
        guard let device = defaultDeviceID() else { throw ActionError.unavailable }
        var address = outputAddress(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw ActionError.failed("Could not change mute.") }
    }

    static func volume() -> Double? {
        guard let device = defaultDeviceID() else { return nil }
        return volume(device: device)
    }

    static func volume(device: AudioDeviceID) -> Double? {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func setVolume(_ volume: Double) throws {
        guard let device = defaultDeviceID() else { throw ActionError.unavailable }
        try setVolume(volume, device: device)
    }

    static func setVolume(_ volume: Double, device: AudioDeviceID) throws {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(min(1, max(0, volume)))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw ActionError.failed("Could not change volume.") }
    }

    /// Fires on every mute or volume change on the current output device,
    /// and follows along when the default device itself changes.
    static let changes: AnyPublisher<Void, Never> = {
        attachDeviceListeners(to: defaultDeviceID())
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            detachDeviceListeners()
            attachDeviceListeners(to: defaultDeviceID())
            subject.send(())
        }
        return subject.eraseToAnyPublisher()
    }()

    private static let subject = PassthroughSubject<Void, Never>()
    private static var listeningDevice: AudioDeviceID?
    private static var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private static var volumeListenerBlock: AudioObjectPropertyListenerBlock?

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func attachDeviceListeners(to device: AudioDeviceID?) {
        guard let device else {
            listeningDevice = nil
            return
        }
        listeningDevice = device
        let muteBlock: AudioObjectPropertyListenerBlock = { _, _ in subject.send(()) }
        let volumeBlock: AudioObjectPropertyListenerBlock = { _, _ in subject.send(()) }
        muteListenerBlock = muteBlock
        volumeListenerBlock = volumeBlock
        var muteAddress = outputAddress(kAudioDevicePropertyMute)
        var volumeAddress = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectAddPropertyListenerBlock(device, &muteAddress, DispatchQueue.main, muteBlock)
        AudioObjectAddPropertyListenerBlock(device, &volumeAddress, DispatchQueue.main, volumeBlock)
    }

    private static func detachDeviceListeners() {
        guard let device = listeningDevice, let muteBlock = muteListenerBlock, let volumeBlock = volumeListenerBlock else { return }
        var muteAddress = outputAddress(kAudioDevicePropertyMute)
        var volumeAddress = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectRemovePropertyListenerBlock(device, &muteAddress, DispatchQueue.main, muteBlock)
        AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, DispatchQueue.main, volumeBlock)
        listeningDevice = nil
        muteListenerBlock = nil
        volumeListenerBlock = nil
    }
}

/// The default input device's mute, the one control every call needs and no
/// menu bar offers.
///
/// Separate from `AudioOutput` rather than a scope argument threaded through
/// it: the two are different devices with different defaults, and mixing
/// them up mutes the wrong end of a call.
enum AudioInput {
    static func defaultDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func isMuted() -> Bool? {
        guard let device = defaultDeviceID() else { return nil }
        var address = inputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Mute where the device has it, volume to zero where it does not.
    ///
    /// Not every input device carries a mute property: several USB
    /// microphones and every aggregate device answer `AudioObjectHasProperty`
    /// with false. Dropping the input volume to zero is the same outcome on
    /// those, and the previous volume is remembered so unmuting does not
    /// leave the microphone at whatever zero was.
    static func setMuted(_ muted: Bool) throws {
        guard let device = defaultDeviceID() else { throw ActionError.unavailable }
        var mute = inputAddress(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &mute) {
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            guard status == noErr else { throw ActionError.failed("Could not change the microphone.") }
            return
        }
        var volume = inputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &volume) else { throw ActionError.unavailable }
        if muted { rememberedVolume = readVolume(device: device) }
        var value = Float32(muted ? 0 : (rememberedVolume ?? 1))
        let status = AudioObjectSetPropertyData(device, &volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw ActionError.failed("Could not change the microphone.") }
    }

    private static var rememberedVolume: Double?

    private static func readVolume(device: AudioDeviceID) -> Double? {
        var address = inputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    /// The input level, on the same virtual main volume the mute fallback
    /// already writes. Nil where the device has no such property, which is
    /// every aggregate device and a few USB microphones.
    static func level() -> Double? {
        guard let device = defaultDeviceID() else { return nil }
        return readVolume(device: device)
    }

    static func setLevel(_ value: Double) throws {
        guard let device = defaultDeviceID() else { throw ActionError.unavailable }
        var address = inputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { throw ActionError.unavailable }
        var level = Float32(max(0, min(1, value)))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil,
                                                UInt32(MemoryLayout<Float32>.size), &level)
        guard status == noErr else { throw ActionError.failed("Could not set the input level.") }
    }

    private static func inputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
