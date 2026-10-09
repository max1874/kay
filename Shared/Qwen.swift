import Foundation

struct KayError: LocalizedError {
    let message: String
    var httpStatus: Int? = nil
    var errorDescription: String? { message }
    var isAuthFailure: Bool { httpStatus == 401 || httpStatus == 403 }
}

enum QwenError {
    static func connection(status: Int?, error: Error?) -> KayError {
        let message: String
        switch status {
        case 401:
            message = String(localized: "Alibaba Cloud rejected this key. Copy the full API key for this workspace.")
        case 403:
            message = String(localized: "This key can't use Qwen ASR in this workspace. Check the key, workspace and service access.")
        default:
            // Never expose request headers, provider payloads or opaque protocol diagnostics in the HUD.
            message = String(localized: "Couldn't reach Alibaba Cloud. Check your network and workspace URL.")
        }
        return KayError(message: message, httpStatus: status)
    }

    static func service(code: String) -> KayError {
        let lower = code.lowercased()
        if lower.contains("auth") || lower.contains("apikey") || lower.contains("api_key") {
            return connection(status: 401, error: nil)
        }
        if lower.contains("permission") || lower.contains("accessdenied") || lower.contains("forbidden") {
            return connection(status: 403, error: nil)
        }
        if lower.contains("limit") || lower.contains("quota") {
            return KayError(message: String(localized: "Qwen ASR is busy or your quota is exhausted. Check your Alibaba Cloud account and try again."))
        }
        return KayError(message: String(localized: "Qwen ASR couldn't finish this dictation. Try again or check your Alibaba Cloud account."))
    }
}

/// One press, one task. Audio is buffered until task-started, sent in order, and all final
/// sentences are joined only at task-finished. Closing the socket never delays delivery.
final class QwenSession {
    static let model = "qwen-audio-3.1-asr-flash-streaming"
    static let defaultWorkspaceURL = "https://dashscope.aliyuncs.com"

    static func endpoint(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(),
              ["https", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              ["", "/", "/api-ws/v1/inference"].contains(parts.path)
        else { return nil }
        let official = host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com"
            || host.hasSuffix(".cn-beijing.maas.aliyuncs.com")
            || host.hasSuffix(".ap-southeast-1.maas.aliyuncs.com")
        guard official else { return nil }
        parts.scheme = "wss"
        parts.path = "/api-ws/v1/inference"
        return parts.url
    }

    private let apiKey: String
    private let workspaceURL: String
    private let taskID = UUID().uuidString
    private let queue = DispatchQueue(label: "kay.qwen")
    private var task: URLSessionWebSocketTask?
    private var buffered: [Data] = []
    private var outgoing: [URLSessionWebSocketTask.Message] = []
    private var sending = false
    private var ready = false
    private var finishing = false
    private var done = false
    private var sentences: [Int: (begin: Int, text: String, final: Bool)] = [:]
    private var completion: ((Result<String, Error>) -> Void)?
    private var readyCompletion: ((Result<Void, Error>) -> Void)?
    private var earlyResult: Result<String, Error>?

    init(apiKey: String, workspaceURL: String) {
        self.apiKey = apiKey
        self.workspaceURL = workspaceURL
    }

    func start(onReady: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async {
            guard !self.done, self.task == nil else { return }
            self.readyCompletion = onReady
            guard let url = Self.endpoint(self.workspaceURL) else {
                self.complete(.failure(KayError(message: String(localized: "Enter the Alibaba Cloud workspace URL from the console."))))
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer " + self.apiKey, forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.enqueueJSON([
                "header": ["action": "run-task", "task_id": self.taskID, "streaming": "duplex"],
                "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                            "model": Self.model, "parameters": ["format": "pcm", "sample_rate": 16000],
                            "input": [:]]
            ])
            self.receive()
            self.queue.asyncAfter(deadline: .now() + 15) {
                if !self.ready && !self.done && self.earlyResult == nil {
                    self.complete(.failure(KayError(message: String(localized: "Couldn't start Qwen ASR. Check your network and workspace URL."))))
                }
            }
        }
    }

    func sendAudio(_ pcm: Data) {
        queue.async {
            guard !self.done, self.earlyResult == nil, !self.finishing, !pcm.isEmpty else { return }
            if self.ready { self.enqueue(.data(pcm)) } else { self.buffered.append(pcm) }
        }
    }

    func finish(lastChunk: Data, timeout: TimeInterval = 10,
                completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard !self.done, self.completion == nil else { return }
            self.completion = completion
            if let early = self.earlyResult {
                self.complete(early)
                return
            }
            self.finishing = true
            if !lastChunk.isEmpty {
                if self.ready { self.enqueue(.data(lastChunk)) } else { self.buffered.append(lastChunk) }
            }
            if self.ready { self.endTask() }
            self.queue.asyncAfter(deadline: .now() + timeout) {
                if !self.done { self.complete(.failure(KayError(message: String(localized: "Recognition timed out.")))) }
            }
        }
    }

    func cancel() {
        queue.async {
            self.done = true
            self.completion = nil
            self.readyCompletion = nil
            self.buffered.removeAll()
            self.outgoing.removeAll()
            self.task?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func endTask() {
        enqueueJSON(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
                     "payload": ["input": [:]]])
    }

    private func enqueueJSON(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let text = String(data: data, encoding: .utf8) else { throw KayError(message: String(localized: "Couldn't start Qwen ASR. Check your network and workspace URL.")) }
            enqueue(.string(text))
        } catch { complete(.failure(error)) }
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        outgoing.append(message)
        pump()
    }

    /// Advance only after the previous send completes, so finish-task cannot overtake audio.
    private func pump() {
        guard !done, earlyResult == nil, !sending, !outgoing.isEmpty, let task else { return }
        sending = true
        let message = outgoing.removeFirst()
        task.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if let error { self.complete(.failure(self.describe(error))) }
                else { self.pump() }
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.done, self.earlyResult == nil else { return }
                switch result {
                case .success(let message):
                    do {
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: throw KayError(message: String(localized: "Alibaba Cloud returned an unreadable response."))
                        }
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let header = json["header"] as? [String: Any],
                              header["task_id"] as? String == self.taskID,
                              let event = header["event"] as? String
                        else { throw KayError(message: String(localized: "Alibaba Cloud returned an unreadable response.")) }
                        try self.handle(event, header: header, payload: json["payload"] as? [String: Any] ?? [:])
                        if !self.done && self.earlyResult == nil { self.receive() }
                    } catch {
                        self.complete(.failure(KayError(message: String(localized: "Alibaba Cloud returned an unreadable response."))))
                    }
                case .failure(let error): self.complete(.failure(self.describe(error)))
                }
            }
        }
    }

    private func handle(_ event: String, header: [String: Any], payload: [String: Any]) throws {
        switch event {
        case "task-started":
            guard !ready else { return }
            ready = true
            let waiting = buffered
            buffered.removeAll()
            for pcm in waiting { enqueue(.data(pcm)) }
            if finishing { endTask() }
            let callback = readyCompletion
            readyCompletion = nil
            callback?(.success(()))
        case "result-generated":
            guard let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }
            if sentence["heartbeat"] as? Bool == true { return }
            guard let id = sentence["sentence_id"] as? Int, let text = sentence["text"] as? String else {
                throw KayError(message: String(localized: "Alibaba Cloud returned an unreadable response."))
            }
            let final = sentence["sentence_end"] as? Bool == true
            if sentences[id]?.final == true && !final { return }
            sentences[id] = (sentence["begin_time"] as? Int ?? 0, text, final)
        case "task-finished":
            guard finishing, sentences.values.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).allSatisfy({ $0.final }) else {
                throw KayError(message: String(localized: "Alibaba Cloud returned an unreadable response."))
            }
            let text = sentences.sorted {
                $0.value.begin == $1.value.begin ? $0.key < $1.key : $0.value.begin < $1.value.begin
            }.map { $0.value.text }.reduce(into: "") { text, sentence in
                if let last = text.last, let first = sentence.first,
                   last.isASCII, !last.isWhitespace, first.isASCII, first.isLetter {
                    text.append(" ")
                }
                text.append(sentence)
            }
            complete(.success(text))
        case "task-failed":
            complete(.failure(QwenError.service(code: header["error_code"] as? String ?? "")))
        default: break
        }
    }

    private func describe(_ error: Error) -> KayError {
        QwenError.connection(status: (task?.response as? HTTPURLResponse)?.statusCode, error: error)
    }

    /// Only on queue. Errors while the key is held are retained until release, as before.
    private func complete(_ result: Result<String, Error>) {
        guard !done else { return }
        if let callback = readyCompletion {
            readyCompletion = nil
            switch result {
            case .success: callback(.success(()))
            case .failure(let error): callback(.failure(error))
            }
        }
        task?.cancel(with: .normalClosure, reason: nil)
        buffered.removeAll()
        outgoing.removeAll()
        guard let completion else {
            if earlyResult == nil { earlyResult = result }
            return
        }
        done = true
        self.completion = nil
        completion(result)
    }
}
