import CoreAudio
import Foundation

/// Pauses what is playing while you dictate with the sound coming out of speakers, and plays it again once the
/// dictation is over. With headphones nothing changes: the microphone doesn't hear them.
///
/// MediaRemote, the system's now-playing service, answers only Apple-entitled processes since macOS 15.4, and
/// `/usr/bin/perl` is one; mediaremote-adapter (`macOS/Vendor`) is a framework perl loads to read and command it.
/// TypeWhisper, VoiceInk and OpenWhispr do the same.
///
/// Never a blind play/pause key: the now-playing app is often a paused one, and a play sent to it starts it
/// (2026-10-18, a probe started Max's Apple Music that way). So Kay pauses only what it has just read as playing,
/// and plays only what it paused, when that is still the item and still paused. Everything runs on a queue of
/// its own: perl takes ~40 ms per call and Core Audio has hung Kay's main thread before (1.6.0).
final class MediaPause {
    static let shared = MediaPause()
    static let defaultsKey = "pauseMediaWhileDictating"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private struct Playing: Equatable {
        let bundle: String?
        let title: String?
        let artist: String?
        let isPlaying: Bool

        func isSameItem(as other: Playing) -> Bool {
            bundle == other.bundle && title == other.title && artist == other.artist
        }
    }

    private let queue = DispatchQueue(label: "kay.media", qos: .userInitiated)
    /// What Kay paused and has not played again yet. Only touched on `queue`.
    private var paused: Playing?

    func pause() {
        guard Self.isOn else { return }
        queue.async { [self] in
            guard paused == nil else { return }
            if let output = Self.headphones() {
                return log.notice("media: left playing, output is \(output)")
            }
            guard let now = read(), now.isPlaying else { return }
            // Before sending: a send that times out may still have paused it, and `resume` plays it only if it is
            // still this item and paused, so remembering too much is safe and remembering too little leaves it paused.
            paused = now
            guard adapter("send", "1") != nil else { return log.error("media: pause may not have been sent") }
            log.notice("media: paused \(now.bundle ?? "?")")
        }
    }

    func resume() {
        queue.async { [self] in
            guard let item = paused else { return }
            paused = nil
            guard let now = read(), now.isSameItem(as: item), !now.isPlaying else {
                return log.notice("media: not resumed, \(item.bundle ?? "?") changed meanwhile")
            }
            guard adapter("send", "0") != nil else { return log.error("media: play not sent") }
            log.notice("media: resumed \(item.bundle ?? "?")")
        }
    }

    /// Before Kay quits: plays what it paused and waits for that, at most `timeout`, so a quit during a dictation
    /// (an update, logout) doesn't leave it paused.
    func resumeBeforeQuit(timeout: TimeInterval) {
        resume()
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func read() -> Playing? {
        guard let data = adapter("get", "--no-artwork"),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Playing(bundle: info["bundleIdentifier"] as? String, title: info["title"] as? String,
                       artist: info["artist"] as? String, isPlaying: info["playing"] as? Bool ?? false)
    }

    /// The adapter's output, or nil when it failed or took over 4 s. A send waits up to 2 s for the player to take
    /// the command (`waitForCommandCompletion`), after perl has started.
    private func adapter(_ arguments: String...) -> Data? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("media: perl didn't start: \(error.localizedDescription)")
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            log.error("media: adapter \(arguments.first ?? "") failed (\(process.terminationStatus))")
            return nil
        }
        return data
    }

    /// The default output's name when it is headphones: Bluetooth (AirPods) or the headphone jack. Everything else
    /// is the room: the Mac's speakers, a display's (the Studio Display reports itself only as USB), HDMI, AirPlay.
    /// A Bluetooth speaker looks like headphones here and keeps playing; Core Audio doesn't tell them apart.
    private static func headphones() -> String? {
        guard let device = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        else { return nil }
        let jack = Microphones.transport(device) == kAudioDeviceTransportTypeBuiltIn
            && value(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) == 0x6864_706E  // 'hdpn'
        guard Microphones.isBluetooth(device) || jack else { return nil }
        return Microphones.string(device, kAudioObjectPropertyName) ?? "headphones"
    }

    private static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
