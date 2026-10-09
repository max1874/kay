import Foundation

/// The user's own Alibaba Cloud credentials, and whether they currently work.
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

    static let apiKeysURL = URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
    static let consoleURL = URL(string: "https://bailian.console.aliyun.com/")!
    private static let workspaceDefaultsKey = "speech.qwen.workspaceURL"

    @Published private(set) var status: Status
    @Published private(set) var maskedKey: String?
    /// A replacement key that failed its test. Kept apart from `status`, which describes the stored
    /// key: a typo in a new key must not make Kay look broken while the saved one still works.
    @Published private(set) var candidateError: String?
    @Published private(set) var workspaceURL: String

    /// Cached so a key press never waits on the Keychain.
    private(set) var apiKey: String?

    var hasKey: Bool { apiKey != nil }

    private init() {
        #if os(macOS)
        // An explicitly prepared, private one-time setup is imported by the signed app so
        // its Keychain item belongs to Kay. Never reinterpret the old Volcengine key as Qwen.
        if Keychain.get() == nil, let setup = QwenSetup.load(),
           QwenSession.endpoint(setup.workspaceURL) != nil,
           Keychain.set(setup.apiKey), Keychain.get() == setup.apiKey {
            UserDefaults.standard.set(setup.workspaceURL, forKey: Self.workspaceDefaultsKey)
            QwenSetup.remove()
        }
        #endif
        let key = Keychain.get()
        apiKey = key
        maskedKey = key.map(Self.mask)
        workspaceURL = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey) ?? QwenSession.defaultWorkspaceURL
        status = key == nil ? .notSet : .saved
    }

    /// Verify the actual ASR task before atomically adopting a candidate key/workspace.
    /// A failed replacement leaves the current, working configuration usable.
    @MainActor
    func test(newKey: String?, newWorkspaceURL: String? = nil) async {
        guard status != .testing else { return }
        let key = (newKey ?? apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateURL = (newWorkspaceURL ?? workspaceURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let isReplacement = apiKey != nil && (key != apiKey || candidateURL != workspaceURL)
        let previous = status
        candidateError = nil
        status = .testing
        switch await Self.verify(key: key, workspaceURL: candidateURL) {
        case .failure(let message):
            if isReplacement { candidateError = message; status = previous }
            else { status = .failed(message) }
        case .success(let ms):
            if key != apiKey {
                guard Keychain.set(key), Keychain.get() == key else {
                    let message = String(localized: "The key works, but Kay couldn't save it to the Keychain.")
                    if isReplacement { candidateError = message; status = previous }
                    else { status = .failed(message) }
                    return
                }
                apiKey = key
                maskedKey = Self.mask(key)
            }
            workspaceURL = candidateURL
            UserDefaults.standard.set(candidateURL, forKey: Self.workspaceDefaultsKey)
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

    /// task-started validates key, workspace and model access without sending microphone audio.
    static func verify(key: String, workspaceURL: String) async -> Verification {
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

    private static func mask(_ key: String) -> String {
        "••••" + key.suffix(4)
    }
}
