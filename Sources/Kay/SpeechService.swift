import Foundation

/// The user's own Volcengine credentials, and whether they currently work.
///
/// One source of truth for "is speech set up": Home's checklist, the Speech Service pane and
/// dictation failures all read and write the same `status`.
final class SpeechService: ObservableObject {
    static let shared = SpeechService()

    enum Status: Equatable {
        case notSet
        /// A key is stored but has not been checked since launch or since the resource changed.
        case saved
        case testing
        case connected(ms: Int)
        case failed(String)

        var isUsable: Bool {
            switch self {
            case .saved, .connected: true
            default: false
            }
        }
    }

    struct Resource: Identifiable {
        let id: String
        let title: String
    }

    /// Doubao Streaming ASR 2.0 is sold two ways; both use the same endpoint.
    static let resources = [
        Resource(id: "volc.seedasr.sauc.duration", title: String(localized: "Hourly")),
        Resource(id: "volc.seedasr.sauc.concurrent", title: String(localized: "Concurrent")),
    ]

    static let apiKeysURL = URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!
    static let activateURL = URL(string: "https://console.volcengine.com/speech/new/setting/activate")!
    static let consoleURL = URL(string: "https://console.volcengine.com/speech/new/overview")!

    private static let resourceDefaultsKey = "speech.resourceId"

    @Published private(set) var status: Status
    @Published private(set) var maskedKey: String?
    /// A replacement key that failed its test. Kept apart from `status`, which describes the stored
    /// key: a typo in a new key must not make Kay look broken while the saved one still works.
    @Published private(set) var candidateError: String?
    @Published var resourceId: String {
        didSet {
            UserDefaults.standard.set(resourceId, forKey: Self.resourceDefaultsKey)
            if apiKey != nil, oldValue != resourceId { status = .saved }
        }
    }

    /// Cached so a key press never waits on the Keychain.
    private(set) var apiKey: String?

    var hasKey: Bool { apiKey != nil }

    private init() {
        if Keychain.get() == nil, let legacy = LegacyConfig.takeApiKey(), Keychain.set(legacy), Keychain.get() == legacy {
            LegacyConfig.remove()
        }
        let key = Keychain.get()
        apiKey = key
        maskedKey = key.map(Self.mask)
        resourceId = UserDefaults.standard.string(forKey: Self.resourceDefaultsKey) ?? Self.resources[0].id
        status = key == nil ? .notSet : .saved
    }

    /// Checks `newKey` (or the stored key when nil) against Volcengine, and only then stores it.
    /// The key is written, read back, and compared before anything says "Connected".
    @MainActor
    func test(newKey: String?) async {
        let key = (newKey ?? apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let isReplacement = apiKey != nil && key != apiKey
        let previous = status
        candidateError = nil
        status = .testing
        switch await Self.verify(key: key, resourceId: resourceId) {
        case .failure(let message):
            if isReplacement {
                candidateError = message
                status = previous
            } else {
                status = .failed(message)
            }
        case .success(let ms):
            if key != apiKey {
                guard Keychain.set(key), Keychain.get() == key else {
                    let message = String(localized: "The key works, but Kay couldn't save it to the Keychain.")
                    if isReplacement { candidateError = message; status = previous } else { status = .failed(message) }
                    return
                }
                apiKey = key
                maskedKey = Self.mask(key)
            }
            status = .connected(ms: ms)
        }
    }

    func clearCandidateError() {
        candidateError = nil
    }

    func remove() {
        candidateError = nil
        Keychain.set("")
        apiKey = nil
        maskedKey = nil
        status = .notSet
    }

    /// Dictation hit an authentication error with the stored key.
    func markFailed(_ message: String) {
        status = .failed(message)
    }

    enum Verification {
        case success(Int)
        case failure(String)
    }

    /// Opens the same WebSocket dictation uses and waits for the handshake, without sending audio.
    /// Volcengine answers the upgrade itself: 401 for a key it doesn't know, 403 for a key whose
    /// account hasn't enabled this resource. Checked 2026-09-30 against the live endpoint.
    static func verify(key: String, resourceId: String) async -> Verification {
        await withCheckedContinuation { continuation in
            let task = URLSession.shared.webSocketTask(with: DoubaoSession.request(apiKey: key, resourceId: resourceId))
            let started = Date()
            task.resume()
            task.sendPing { error in
                let status = (task.response as? HTTPURLResponse)?.statusCode
                task.cancel(with: .normalClosure, reason: nil)
                if let error {
                    continuation.resume(returning: .failure(DoubaoError.message(status: status, error: error)))
                } else {
                    continuation.resume(returning: .success(Int(Date().timeIntervalSince(started) * 1000)))
                }
            }
        }
    }

    private static func mask(_ key: String) -> String {
        "••••" + key.suffix(4)
    }
}
