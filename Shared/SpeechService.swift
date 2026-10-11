import Foundation

/// A speech recognition service Kay can dictate with, using the user's own key.
enum SpeechProvider: String, CaseIterable, Identifiable {
    case qwen, doubao

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qwen: String(localized: "Alibaba Qwen ASR")
        case .doubao: String(localized: "Volcengine Doubao ASR")
        }
    }

    /// For menus and status lines.
    var shortName: String {
        switch self {
        case .qwen: String(localized: "Qwen")
        case .doubao: String(localized: "Doubao")
        }
    }

    var model: String {
        switch self {
        case .qwen: String(localized: "Qwen Audio 3.1 · streaming")
        case .doubao: String(localized: "Streaming ASR 2.0 · sentence mode")
        }
    }

    var consoleName: String {
        switch self {
        case .qwen: String(localized: "Alibaba Cloud Console")
        case .doubao: String(localized: "Volcengine Console")
        }
    }

    var apiKeysURL: URL {
        switch self {
        case .qwen: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
        case .doubao: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!
        }
    }

    var consoleURL: URL {
        switch self {
        case .qwen: URL(string: "https://bailian.console.aliyun.com/")!
        case .doubao: URL(string: "https://console.volcengine.com/speech/new/overview")!
        }
    }

    var account: Keychain.Account {
        switch self {
        case .qwen: .dashscope
        case .doubao: .volcengine
        }
    }

    /// Where the provider's one setting besides the key is stored: Qwen's workspace URL, Doubao's
    /// resource ID (how the service was bought). The keys are the ones each was first stored under.
    fileprivate var settingDefaultsKey: String {
        switch self {
        case .qwen: "speech.qwen.workspaceURL"
        case .doubao: "speech.resourceId"
        }
    }

    fileprivate var defaultSetting: String {
        switch self {
        case .qwen: QwenSession.defaultWorkspaceURL
        case .doubao: DoubaoSession.resources[0].id
        }
    }
}

/// One press, one recognition task, whichever provider runs it. Audio sent before `start()` is kept
/// and sent once the task can take it.
protocol SpeechSession: AnyObject {
    var provider: SpeechProvider { get }
    func start()
    func sendAudio(_ pcm: Data)
    func finish(lastChunk: Data, timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

extension QwenSession: SpeechSession {}
extension DoubaoSession: SpeechSession {}

/// The user's own keys for each provider, which one dictation uses, and whether they currently work.
///
/// One source of truth for "is speech set up": Home's checklist, the Speech Service pane and
/// dictation failures all read and write the same statuses. Each provider keeps its own key and
/// status, so switching never touches the other's.
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

    private static let providerDefaultsKey = "speech.provider"

    /// The provider dictation uses. Only one with a key can be chosen.
    @Published private(set) var provider: SpeechProvider
    @Published private var statuses: [SpeechProvider: Status]
    @Published private var maskedKeys: [SpeechProvider: String]
    /// A replacement key that failed its test. Kept apart from the status, which describes the stored
    /// key: a typo in a new key must not make Kay look broken while the saved one still works.
    @Published private var candidateErrors: [SpeechProvider: String] = [:]
    @Published private var settings: [SpeechProvider: String]

    /// Cached so a key press never waits on the Keychain.
    private var keys: [SpeechProvider: String]
    /// The latest pick still being checked; a later pick, or a pick of the current one, supersedes it.
    private var pending: SpeechProvider?

    // The chosen provider's, for everything that only cares about dictating.
    var status: Status { status(of: provider) }
    var maskedKey: String? { maskedKeys[provider] }
    var candidateError: String? { candidateErrors[provider] }
    var apiKey: String? { keys[provider] }
    var hasKey: Bool { apiKey != nil }
    var workspaceURL: String { setting(of: .qwen) }

    func status(of provider: SpeechProvider) -> Status { statuses[provider] ?? .notSet }
    func maskedKey(of provider: SpeechProvider) -> String? { maskedKeys[provider] }
    func candidateError(of provider: SpeechProvider) -> String? { candidateErrors[provider] }
    func hasKey(_ provider: SpeechProvider) -> Bool { keys[provider] != nil }
    func setting(of provider: SpeechProvider) -> String { settings[provider] ?? provider.defaultSetting }

    private init() {
        #if os(macOS)
        // An explicitly prepared, private one-time setup is imported by the signed app so
        // its Keychain item belongs to Kay. Never reinterpret the Volcengine key as Qwen.
        if Keychain.get(.dashscope) == nil, let setup = QwenSetup.load(),
           QwenSession.endpoint(setup.workspaceURL) != nil,
           Keychain.set(setup.apiKey, for: .dashscope), Keychain.get(.dashscope) == setup.apiKey {
            UserDefaults.standard.set(setup.workspaceURL, forKey: SpeechProvider.qwen.settingDefaultsKey)
            QwenSetup.remove()
        }
        #endif
        var keys: [SpeechProvider: String] = [:]
        var settings: [SpeechProvider: String] = [:]
        for provider in SpeechProvider.allCases {
            keys[provider] = Keychain.get(provider.account)
            settings[provider] = UserDefaults.standard.string(forKey: provider.settingDefaultsKey) ?? provider.defaultSetting
        }
        self.keys = keys
        self.settings = settings
        maskedKeys = keys.mapValues(Self.mask)
        statuses = keys.mapValues { _ in .saved }
        // Qwen until the user picks: what 1.6 dictated with.
        provider = SpeechProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerDefaultsKey) ?? "") ?? .qwen
    }

    /// Dictate with `provider` from the next press on, once its key is known to work: a key that hasn't
    /// passed a test since launch is tested first, and dictation stays where it was if it fails. A provider
    /// without a key can't be chosen. Only the latest pick counts.
    @MainActor
    func select(_ provider: SpeechProvider) {
        pending = provider
        guard provider != self.provider, hasKey(provider) else { pending = nil; return }
        if case .connected = status(of: provider) {
            adopt(provider)
            return
        }
        Task { @MainActor in
            await test(provider, newKey: nil)
            guard pending == provider, case .connected = status(of: provider) else { return }
            adopt(provider)
        }
    }

    @MainActor
    private func adopt(_ provider: SpeechProvider) {
        pending = nil
        self.provider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.providerDefaultsKey)
    }

    /// A recognition task for the chosen provider, or nil when it has no key.
    func makeSession() -> SpeechSession? {
        guard let key = apiKey else { return nil }
        switch provider {
        case .qwen: return QwenSession(apiKey: key, workspaceURL: setting(of: .qwen))
        case .doubao: return DoubaoSession(apiKey: key, resourceId: setting(of: .doubao))
        }
    }

    /// Verify the actual ASR service before atomically adopting a candidate key or setting (Qwen's
    /// workspace URL, Doubao's resource). A failed replacement leaves the current configuration usable.
    /// `provider` defaults to the chosen one.
    @MainActor
    func test(_ provider: SpeechProvider? = nil, newKey: String?, newSetting: String? = nil) async {
        let provider = provider ?? self.provider
        guard status(of: provider) != .testing else { return }
        let stored = keys[provider]
        let key = (newKey ?? stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (newSetting ?? setting(of: provider)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let isReplacement = stored != nil && (key != stored || candidate != setting(of: provider))
        let previous = status(of: provider)
        candidateErrors[provider] = nil
        statuses[provider] = .testing
        let verification: Verification
        switch provider {
        case .qwen: verification = await Self.verifyQwen(key: key, workspaceURL: candidate)
        case .doubao: verification = await Self.verifyDoubao(key: key, resourceId: candidate)
        }
        // Removed while the test ran: the removal wins, whatever the test found.
        guard keys[provider] == stored else {
            if keys[provider] == nil { statuses[provider] = nil }
            return
        }
        switch verification {
        case .failure(let message):
            if isReplacement { candidateErrors[provider] = message; statuses[provider] = previous }
            else { statuses[provider] = .failed(message) }
        case .success(let ms):
            if key != stored {
                guard Keychain.set(key, for: provider.account), Keychain.get(provider.account) == key else {
                    let message = String(localized: "The key works, but Kay couldn't save it to the Keychain.")
                    if isReplacement { candidateErrors[provider] = message; statuses[provider] = previous }
                    else { statuses[provider] = .failed(message) }
                    return
                }
                keys[provider] = key
                maskedKeys[provider] = Self.mask(key)
            }
            settings[provider] = candidate
            UserDefaults.standard.set(candidate, forKey: provider.settingDefaultsKey)
            statuses[provider] = .connected(ms: ms)
        }
    }

    /// The pre-provider call, still used by the iPhone app: Qwen's key and workspace URL.
    @MainActor
    func test(newKey: String?, newWorkspaceURL: String?) async {
        await test(.qwen, newKey: newKey, newSetting: newWorkspaceURL)
    }

    func clearCandidateError(of provider: SpeechProvider? = nil) {
        candidateErrors[provider ?? self.provider] = nil
    }

    /// Deletes the key. Dictation stays on this provider, now without a key, until another is chosen.
    func remove(_ provider: SpeechProvider? = nil) {
        let provider = provider ?? self.provider
        candidateErrors[provider] = nil
        Keychain.set("", for: provider.account)
        keys[provider] = nil
        maskedKeys[provider] = nil
        statuses[provider] = nil
    }

    /// Dictation hit an authentication error with the stored key.
    func markFailed(_ message: String, provider: SpeechProvider? = nil) {
        let provider = provider ?? self.provider
        guard hasKey(provider) else { return }
        statuses[provider] = .failed(message)
    }

    enum Verification {
        case success(Int)
        case failure(String)
    }

    /// task-started validates key, workspace and model access without sending microphone audio.
    static func verifyQwen(key: String, workspaceURL: String) async -> Verification {
        await withCheckedContinuation { continuation in
            let session = QwenSession(apiKey: key, workspaceURL: workspaceURL)
            let started = Date()
            session.start { result in
                session.cancel()
                switch result {
                case .success:
                    continuation.resume(returning: .success(Int(Date().timeIntervalSince(started) * 1000)))
                case .failure(let error):
                    continuation.resume(returning: .failure(error.localizedDescription))
                }
            }
        }
    }

    /// Opens the same WebSocket dictation uses and waits for the handshake, without sending audio.
    /// Volcengine answers the upgrade itself: 401 for a key it doesn't know, 403 for a key whose
    /// account hasn't enabled this resource. Checked 2026-09-30 against the live endpoint.
    static func verifyDoubao(key: String, resourceId: String) async -> Verification {
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
