import AppKit
import CoreAudio
import CoreWLAN
import IOBluetooth

/// The three lists a cell can offer instead of a plain on and off: paired
/// Bluetooth devices, Wi-Fi networks this Mac already knows, and the output
/// devices sound can go to.
///
/// Lists rather than a designed panel: this is a menu the system draws, so it
/// is keyboard navigable, it scrolls when it is long, and it goes away the way
/// every other menu does. The plain click on the cell still toggles.

// MARK: - Audio inputs

/// The microphones sound can come from. The same code as the output list with
/// the scope and the default device selector changed, which is why it lives
/// beside it rather than growing a parameter on it.
enum AudioInputs {
    static func inputs() -> [AudioDevices.Device] {
        let current = AudioInput.defaultDeviceID()
        return AudioDevices.allIDs().compactMap { device in
            guard AudioDevices.hasStream(device, scope: kAudioObjectPropertyScopeInput),
                  let name = AudioDevices.name(of: device) else { return nil }
            return AudioDevices.Device(id: device, name: name, isDefault: device == current)
        }
    }

    static func setDefault(_ id: AudioDeviceID) throws {
        var device = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        guard status == noErr else { throw ActionError.failed("That input could not be selected.") }
    }
}

// MARK: - Bluetooth

enum BluetoothDevices {
    struct Device: Equatable {
        let name: String
        let address: String
        let isConnected: Bool
    }

    /// Paired devices, connected ones first.
    ///
    /// `IOBluetoothDevice` is the public framework rather than the private
    /// symbols the power toggle uses, so this does not go through
    /// `PrivateCall`. It is still asked on a background queue with a deadline
    /// by the caller: the Bluetooth stack on this Mac has wedged before.
    static func paired() -> [Device] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.map {
            Device(name: $0.nameOrAddress ?? $0.addressString ?? "Unknown",
                   address: $0.addressString ?? "",
                   isConnected: $0.isConnected())
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name.lowercased()) < ($1.isConnected ? 0 : 1, $1.name.lowercased()) }
    }

    /// Connects a disconnected device, disconnects a connected one. Both
    /// calls block until the radio answers, so this is never run on the main
    /// thread.
    static func toggle(address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address) else {
            throw ActionError.unavailable
        }
        let status: IOReturn = device.isConnected() ? device.closeConnection() : device.openConnection()
        guard status == kIOReturnSuccess else {
            throw ActionError.failed("\(device.nameOrAddress ?? "That device") did not answer.")
        }
    }
}

// MARK: - Wi-Fi

enum WiFiNetworks {
    struct Network: Equatable {
        let ssid: String
        let isCurrent: Bool
    }

    static var interfaceName: String? { CWWiFiClient.shared().interface()?.interfaceName }

    /// The networks this Mac has joined before, which is the list that can be
    /// joined again without a password sheet or a scan.
    ///
    /// A scan would need Location permission on this system and would still
    /// only add networks the user has to type a password for. Known networks
    /// have their password in the keychain already.
    static func known() -> [Network] {
        guard let interface = CWWiFiClient.shared().interface() else { return [] }
        let current = interface.ssid()
        let profiles = interface.configuration()?.networkProfiles.compactMap { ($0 as? CWNetworkProfile)?.ssid } ?? []
        var seen = Set<String>()
        return profiles.compactMap { ssid in
            guard seen.insert(ssid).inserted else { return nil }
            return Network(ssid: ssid, isCurrent: ssid == current)
        }
    }

    /// Joins through `networksetup`, which finds the password in the keychain
    /// for a network this Mac knows. `CWInterface.associate` needs a
    /// `CWNetwork` from a scan, and a scan needs Location.
    static func join(_ ssid: String,
                     run: (String, [String]) async throws -> ShellResult = { try await Shell.run($0, $1) }) async throws {
        guard let interface = interfaceName else { throw ActionError.unavailable }
        let result = try await run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid])
        // networksetup reports a refusal on stdout with a zero status, which
        // is why this reads the output rather than the exit code alone.
        let output = (result.stdout + result.stderr).lowercased()
        guard result.status == 0, !output.contains("could not"), !output.contains("failed") else {
            throw ActionError.failed("Could not join \(ssid).")
        }
    }
}

// MARK: - Sound output

enum AudioDevices {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    /// Every device sound can actually come out of: the ones with at least
    /// one output stream. Microphones and aggregate inputs answer the same
    /// property query and would otherwise be in the list.
    static func outputs() -> [Device] {
        let current = AudioOutput.defaultDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasStream(id, scope: kAudioObjectPropertyScopeOutput), let name = name(of: id) else { return nil }
            return Device(id: id, name: name, isDefault: id == current)
        }
    }

    /// Every audio device the system knows, in whatever order it gives them.
    fileprivate static func allIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func setDefault(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard status == noErr else { throw ActionError.failed("That output would not take the sound.") }
    }

    /// Whether the device carries channels in that direction. An output only
    /// device answers false for the input scope and the other way round, which
    /// is what keeps a microphone out of the output list.
    fileprivate static func hasStream(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    fileprivate static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        let string = name as String
        return string.isEmpty ? nil : string
    }
}
