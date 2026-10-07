import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// 采集麦克风并转成 16kHz / 16bit / 单声道 PCM，按 200ms 分包回调。
final class AudioCapture {
    static let chunkBytes = 16000 * 2 / 5  // 200ms

    var onChunk: ((Data) -> Void)?
    /// Loudness of each converted buffer, 0...1, about 20 times a second. Drives the waveforms.
    var onLevel: ((Float) -> Void)?
#if os(macOS)
    /// The input device to record from; nil is the system default. Set before `start()`.
    var inputDevice: AudioDeviceID?
#endif

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                       channels: 1, interleaved: true)!
    private let queue = DispatchQueue(label: "kay.audio")
    private var converter: AVAudioConverter?
    private var buffer = Data()
    private var recordedBytes = 0

    /// How much audio has been captured so far, which is what Volcengine bills by.
    var recordedSeconds: Double {
        queue.sync { Double(recordedBytes) / (16000 * 2) }
    }

    func start() throws {
        let input = engine.inputNode
#if os(macOS)
        // On the input unit before its format is read: the format is the device's. If the device can't be
        // set (unplugged since it was looked up), the system default records instead.
        if var device = inputDevice, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
#endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw KayError(message: String(localized: "No microphone input is available."))
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.convert(buf)
        }
        engine.prepare()
        try engine.start()
    }

    /// 停止采集，返回尚未发出的尾部音频。
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return queue.sync {
            let rest = buffer
            buffer = Data()
            return rest
        }
    }

    /// RMS on a log scale, so ordinary speech fills most of the range instead of a sliver of it.
    private static func level(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let v = Float(samples[i]) / Float(Int16.max)
            sum += v * v
        }
        let db = 20 * log10(max(sqrt(sum / Float(count)), 1e-5))
        return min(max((db + 55) / 45, 0), 1)  // -55 dB → 0, -10 dB → 1
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        onLevel?(Self.level(samples[0], count: Int(out.frameLength)))

        queue.async {
            self.buffer.append(data)
            self.recordedBytes += data.count
            while self.buffer.count >= Self.chunkBytes {
                let chunk = self.buffer.prefix(Self.chunkBytes)
                self.buffer.removeFirst(Self.chunkBytes)
                self.onChunk?(Data(chunk))
            }
        }
    }
}
