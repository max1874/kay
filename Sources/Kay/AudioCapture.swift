import AVFoundation

/// 采集麦克风并转成 16kHz / 16bit / 单声道 PCM，按 200ms 分包回调。
final class AudioCapture {
    static let chunkBytes = 16000 * 2 / 5  // 200ms

    var onChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                       channels: 1, interleaved: true)!
    private let queue = DispatchQueue(label: "kay.audio")
    private var converter: AVAudioConverter?
    private var buffer = Data()

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw KayError(message: "没有可用的麦克风输入")
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

        queue.async {
            self.buffer.append(data)
            while self.buffer.count >= Self.chunkBytes {
                let chunk = self.buffer.prefix(Self.chunkBytes)
                self.buffer.removeFirst(Self.chunkBytes)
                self.onChunk?(Data(chunk))
            }
        }
    }
}
