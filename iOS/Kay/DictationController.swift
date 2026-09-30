import ActivityKit
import AVFoundation
import UIKit

/// One dictation at a time: start streams the microphone to Doubao, stop waits for the final text and
/// puts it on the clipboard. Driven by the control (Action Button, Control Center, Lock Screen) and by
/// the button in the app, which call the same `toggle()`.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State { case idle, recording, recognizing }

    @Published private(set) var state = State.idle
    @Published private(set) var history: [HistoryEntry] = HistoryStore.load()
    @Published private(set) var lastError: String?

    private var capture: AudioCapture?
    private var session: DoubaoSession?
    private var activity: Activity<DictationActivityAttributes>?
    private var startedAt = Date()

    func toggle() async throws {
        switch state {
        case .idle: try start()
        case .recording: await stop()
        case .recognizing: break
        }
    }

    func start() throws {
        guard state == .idle else { return }
        lastError = nil
        let speech = SpeechService.shared
        guard let apiKey = speech.apiKey else {
            throw fail(String(localized: "Add your Volcengine API key in Kay first."))
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw fail(String(localized: "Kay can't use the microphone. Open Kay once and allow it."))
        }

        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
        } catch {
            throw fail(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
        }

        let session = DoubaoSession(apiKey: apiKey, resourceId: speech.resourceId)
        let capture = AudioCapture()
        capture.onChunk = { [weak session] in session?.sendAudio($0) }
        do {
            try capture.start()
        } catch {
            try? audio.setActive(false)
            throw fail(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
        }
        session.start()

        self.session = session
        self.capture = capture
        startedAt = Date()
        state = .recording
        startActivity()
    }

    func stop() async {
        guard state == .recording, let session, let capture else { return }
        let rest = capture.stop()
        let seconds = capture.recordedSeconds
        self.capture = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .recognizing
        await updateActivity(.recognizing, message: nil)
        let releasedAt = Date()
        let result = await withCheckedContinuation { continuation in
            session.finish(lastChunk: rest) { continuation.resume(returning: $0) }
        }
        self.session = nil
        state = .idle
        let ms = Int(Date().timeIntervalSince(releasedAt) * 1000)

        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                await endActivity(.failed, message: String(localized: "Didn't catch that."))
                return
            }
            UIPasteboard.general.string = text
            record(HistoryEntry(date: Date(), text: text, audioSeconds: seconds, latencyMs: ms))
            await endActivity(.copied, message: text)
        case .failure(let error):
            let message = error.localizedDescription
            lastError = message
            if let kayError = error as? KayError, kayError.isAuthFailure {
                SpeechService.shared.markFailed(message)
            }
            record(HistoryEntry(date: Date(), text: "", audioSeconds: seconds, latencyMs: nil, error: message))
            await endActivity(.failed, message: message)
        }
    }

    // MARK: - History

    func copy(_ entry: HistoryEntry) {
        UIPasteboard.general.string = entry.text
    }

    func delete(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        HistoryStore.save(history)
    }

    private func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > HistoryStore.limit { history.removeLast(history.count - HistoryStore.limit) }
        HistoryStore.save(history)
    }

    private func fail(_ message: String) -> KayError {
        lastError = message
        return KayError(message: message)
    }

    // MARK: - Live Activity

    /// Required, not decoration: the system only lets an `AudioRecordingIntent` keep the microphone
    /// while a Live Activity is up.
    private func startActivity() {
        let state = DictationActivityAttributes.ContentState(phase: .listening, startedAt: startedAt, message: nil)
        activity = try? Activity.request(attributes: DictationActivityAttributes(),
                                         content: .init(state: state, staleDate: nil))
    }

    private func updateActivity(_ phase: DictationActivityAttributes.ContentState.Phase, message: String?) async {
        let state = DictationActivityAttributes.ContentState(phase: phase, startedAt: startedAt, message: message)
        await activity?.update(.init(state: state, staleDate: nil))
    }

    /// Leaves the result on the Lock Screen / Dynamic Island for a few seconds, then goes away.
    private func endActivity(_ phase: DictationActivityAttributes.ContentState.Phase, message: String) async {
        let state = DictationActivityAttributes.ContentState(phase: phase, startedAt: startedAt, message: message)
        await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4))
        activity = nil
    }
}
