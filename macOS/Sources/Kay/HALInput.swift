import AVFoundation
import AudioToolbox
import CoreAudio

/// One input device through an AUHAL unit of Kay's own, set to that device before it is initialized.
///
/// AVAudioEngine's input node always attaches to the system default input first and only then lets Kay switch
/// it to the chosen microphone. On 2026-10-09 that first, unwanted attach (the Studio Display's microphone, with
/// the MacBook's chosen) failed inside Core Audio with 'nope', and AVAudioEngine then looped on the main thread
/// for good. Here the default input is never touched.
///
/// Buffers of about 50 ms arrive on `queue`: the device's first channel, at its own rate, as Float32.
final class HALInput {
    let format: AVAudioFormat
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let unit: AudioUnit
    private let queue = DispatchQueue(label: "kay.audio.input")
    /// Filled on `queue` until it holds `bufferFrames`, then handed to `onBuffer`.
    private var gathering: AVAudioPCMBuffer?
    private let bufferFrames: AVAudioFrameCount
    private var maxFrames: UInt32 = 4096

    init(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw KayError(message: "AUHAL component not found")
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "AudioComponentInstanceNew")
        guard let unit = instance else { throw KayError(message: "AudioComponentInstanceNew returned no unit") }

        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flag = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flag),
                           "enable input")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flag),
                           "disable output")
            var device = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                           "set device \(device)")

            // Input scope of the input bus is the device's side. Kay takes its first channel at the same rate:
            // speech is mono, and a format of more than two channels is one AVAudioFormat can't even describe.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size),
                           "read device format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: 1, interleaved: false) else {
                throw KayError(message: "device \(device) has no usable input format (\(hardware.mSampleRate) Hz, \(hardware.mChannelsPerFrame) ch)")
            }
            var map: [Int32] = [0]
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                                &map, UInt32(MemoryLayout<Int32>.size)),
                           "map channel 1 of \(hardware.mChannelsPerFrame)")
            var client = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size),
                           "set client format")
            self.format = format
            self.unit = unit
            bufferFrames = AVAudioFrameCount(format.sampleRate / 20)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, &size) == noErr,
           frames > 0 {
            maxFrames = frames
        }
        var callback = AURenderCallbackStruct(inputProc: HALInput.render,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                           "set input callback")
            try Self.check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    func start() throws {
        try Self.check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    /// No more input callbacks once this returns; the partly gathered tail goes to `onBuffer` before it does.
    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        queue.sync {
            if let gathering, gathering.frameLength > 0 { onBuffer?(gathering) }
            gathering = nil
        }
    }

    /// On Core Audio's I/O thread: pull this slice into a buffer of its own and move on.
    private static let render: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        let input = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: max(frames, 1)) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(input.unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        input.queue.async { input.gather(buffer) }
        return noErr
    }

    private func gather(_ slice: AVAudioPCMBuffer) {
        if gathering == nil {
            gathering = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames + maxFrames)
        }
        guard let gathering, let from = slice.floatChannelData, let to = gathering.floatChannelData else { return }
        let count = Int(min(slice.frameLength, gathering.frameCapacity - gathering.frameLength))
        let at = Int(gathering.frameLength)
        for channel in 0..<Int(format.channelCount) {
            (to[channel] + at).update(from: from[channel], count: count)
        }
        gathering.frameLength += AVAudioFrameCount(count)
        if gathering.frameLength >= bufferFrames {
            onBuffer?(gathering)
            self.gathering = nil
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw KayError(message: "\(step) failed: \(fourCC(status)) (\(status))")
    }

    static func fourCC(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return "\(status)" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}
