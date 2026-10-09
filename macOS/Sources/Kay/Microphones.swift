import CoreAudio
import Foundation

/// Audio input devices, from Core Audio. Kay records from the one picked in Settings, remembered by UID —
/// the UID survives unplugging and reconnecting, the numeric device id doesn't — or from the system default.
enum Microphones {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// The chosen device's UID; empty is the system default.
    static let storageKey = "microphoneUID"

    static func all() -> [Device] {
        deviceIDs().filter(hasInput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  // The aggregates macOS builds for itself while an app records aren't microphones.
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    /// What a dictation should record from: the chosen device if it is connected, otherwise nil, which is
    /// the system default.
    static func chosen() -> (id: AudioDeviceID, name: String)? {
        guard let uid = UserDefaults.standard.string(forKey: storageKey), !uid.isEmpty else { return nil }
        for id in deviceIDs() where string(id, kAudioDevicePropertyDeviceUID) == uid && hasInput(id) {
            return (id, string(id, kAudioObjectPropertyName) ?? uid)
        }
        return nil
    }

    static func defaultName() -> String? {
        systemDefault()?.name
    }

    static func systemDefault() -> (id: AudioDeviceID, name: String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return (id, string(id, kAudioObjectPropertyName) ?? "device \(id)")
    }

    /// The Mac's own microphone, if it has one (a MacBook does, a Mac mini doesn't): the fallback when the
    /// microphone a dictation should use doesn't start.
    static func builtIn() -> (id: AudioDeviceID, name: String)? {
        for id in deviceIDs() where transport(id) == kAudioDeviceTransportTypeBuiltIn && hasInput(id) {
            return (id, string(id, kAudioObjectPropertyName) ?? "built-in microphone")
        }
        return nil
    }

    /// Bluetooth input starts by switching the headset's profile, which takes seconds rather than milliseconds.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let type = transport(id)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
