import Foundation

struct KayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 豆包流式语音识别（一句话模式 bigmodel_nostream）的二进制帧。
/// 协议：4 字节 header + 4 字节大端 payload size + payload。不压缩，服务端会用同样方式回包。
enum DoubaoFrame {
    static func fullClientRequest(_ json: Data) -> Data {
        header(type: 0b0001, flags: 0b0000, serialization: 0b0001) + size(json) + json
    }

    /// last=true 时为负包，通知服务端音频结束。
    static func audio(_ pcm: Data, last: Bool) -> Data {
        header(type: 0b0010, flags: last ? 0b0010 : 0b0000, serialization: 0b0000) + size(pcm) + pcm
    }

    /// 返回 (是否最后一包, JSON)。服务端错误帧抛出异常。
    static func parse(_ data: Data) throws -> (isLast: Bool, json: [String: Any]?) {
        let b = [UInt8](data)
        guard b.count >= 4 else { throw KayError(message: "响应帧过短") }
        let headerSize = Int(b[0] & 0x0F) * 4
        let type = b[1] >> 4, flags = b[1] & 0x0F
        var p = headerSize

        if type == 0b1111 {
            let code = u32(b, p), len = Int(u32(b, p + 4))
            let msg = String(decoding: b[(p + 8)..<min(b.count, p + 8 + len)], as: UTF8.self)
            throw KayError(message: "服务端错误 \(code)：\(msg)")
        }
        if flags & 0b0001 != 0 { p += 4 }  // sequence
        guard b.count >= p + 4 else { throw KayError(message: "响应帧不完整") }
        let len = Int(u32(b, p))
        let payload = Data(b[(p + 4)..<min(b.count, p + 4 + len)])
        guard b[2] & 0x0F == 0 else { throw KayError(message: "不支持的压缩格式") }
        let json = payload.isEmpty ? nil : try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return (flags & 0b0010 != 0, json)
    }

    private static func header(type: UInt8, flags: UInt8, serialization: UInt8) -> Data {
        Data([0x11, type << 4 | flags, serialization << 4, 0x00])
    }

    private static func size(_ d: Data) -> Data {
        withUnsafeBytes(of: UInt32(d.count).bigEndian) { Data($0) }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        b[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// 一次按住说话对应一个会话：按下时建连并边录边推流，松开时发负包并等待最终结果。
final class DoubaoSession {
    private static let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!
    private static let request: Data = try! JSONSerialization.data(withJSONObject: [
        "user": ["uid": "kay"],
        "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
        "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "enable_ddc": true],
    ])

    private let apiKey: String
    private let queue = DispatchQueue(label: "kay.doubao")
    private var task: URLSessionWebSocketTask?
    private var latest = ""
    private var completion: ((Result<String, Error>) -> Void)?
    private var earlyResult: Result<String, Error>?
    private var done = false

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() {
        var req = URLRequest(url: Self.url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        let task = URLSession.shared.webSocketTask(with: req)
        self.task = task
        task.resume()
        // 握手完成前的发送会排队，按顺序发出
        send(DoubaoFrame.fullClientRequest(Self.request))
        receive()
    }

    func sendAudio(_ pcm: Data) {
        send(DoubaoFrame.audio(pcm, last: false))
    }

    func finish(lastChunk: Data, timeout: TimeInterval = 10,
                completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            self.completion = completion
            if let early = self.earlyResult {
                self.complete(early)
                return
            }
            self.send(DoubaoFrame.audio(lastChunk, last: true))
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.complete(.failure(KayError(message: "识别超时")))
            }
        }
    }

    func cancel() {
        queue.async {
            self.done = true
            self.task?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.complete(.failure(error)) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(.data(let data)):
                    do {
                        let (isLast, json) = try DoubaoFrame.parse(data)
                        if let text = (json?["result"] as? [String: Any])?["text"] as? String {
                            self.latest = text
                        }
                        if isLast { self.complete(.success(self.latest)) } else { self.receive() }
                    } catch {
                        self.complete(.failure(error))
                    }
                case .success:
                    self.receive()
                case .failure(let error):
                    self.complete(.failure(error))
                }
            }
        }
    }

    /// 只在 queue 上调用。松开前出错会先暂存，等 finish 时再回调。
    private func complete(_ result: Result<String, Error>) {
        guard !done else { return }
        guard let completion else {
            if earlyResult == nil { earlyResult = result }
            return
        }
        done = true
        self.completion = nil
        task?.cancel(with: .normalClosure, reason: nil)
        completion(result)
    }
}
