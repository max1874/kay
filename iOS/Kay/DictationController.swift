import ActivityKit
import AVFoundation
import UIKit
import WidgetKit

/// One dictation at a time: start streams the microphone to Doubao, stop waits for the final text and
/// puts it on the clipboard. Driven by the control (Action Button, Control Center, Lock Screen) and by
/// the button in the app, which call the same `toggle()`.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State { case idle, recording, recognizing }

    @Published private(set) var state = State.idle {
        didSet {
            guard (state == .recording) != SharedState.isRecording else { return }
            SharedState.isRecording = state == .recording
            ControlCenter.shared.reloadControls(ofKind: SharedState.controlKind)
        }
    }
    @Published private(set) var history: [HistoryEntry] = HistoryStore.load()
    @Published private(set) var lastError: String?

    private var capture: AudioCapture?
    private var session: DoubaoSession?
    private var activity: Activity<DictationActivityAttributes>?
    private var startedAt = Date()
    /// Text iOS wouldn't let Kay put on the clipboard from the background; copied when Kay comes forward.
    private var pendingCopy: String?

    private init() {
        // A fresh process is never listening, whatever a previous one left behind.
        if SharedState.isRecording {
            SharedState.isRecording = false
            ControlCenter.shared.reloadControls(ofKind: SharedState.controlKind)
        }
    }

    func toggle() async throws {
        switch state {
        case .idle: try start()
        case .recording: await stop()
        case .recognizing: break
        }
    }

    #if DEBUG
    /// Puts up a Live Activity in `phase` without recording, to look at it on a device:
    /// `devicectl device process launch … com.max1874.kay -KayDemo listening`. `end` takes it down.
    func demo(_ name: String) async {
        for activity in Activity<DictationActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let phase = DictationActivityAttributes.ContentState.Phase(rawValue: name) else { return }
        let message = phase == .failed ? "The microphone didn't start." : "今天下午三点在会议室开会，记得带上 MacBook 和那份 roadmap。"
        let state = DictationActivityAttributes.ContentState(phase: phase, startedAt: Date().addingTimeInterval(-12), message: message)
        _ = try? Activity.request(attributes: DictationActivityAttributes(), content: .init(state: state, staleDate: nil))
    }
    #endif

    /// Called when Kay comes to the foreground.
    func becameActive() {
        guard let text = pendingCopy else { return }
        pendingCopy = nil
        UIPasteboard.general.string = text
        Trace.log("pending copy done")
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

        // The Live Activity comes first: from the control Kay is in the background, and iOS only lets an
        // AudioRecordingIntent activate the microphone once its Live Activity is up.
        startedAt = Date()
        startActivity()

        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            Trace.log("setActive failed: \(error as NSError)")
            let message = String(localized: "The microphone didn't start: \(error.localizedDescription)")
            Task { await endActivity(.failed, message: message) }
            throw fail(message)
        }

        let session = DoubaoSession(apiKey: apiKey, resourceId: speech.resourceId)
        let capture = AudioCapture()
        capture.onChunk = { [weak session] in session?.sendAudio($0) }
        do {
            try capture.start()
        } catch {
            try? audio.setActive(false)
            let message = String(localized: "The microphone didn't start: \(error.localizedDescription)")
            Task { await endActivity(.failed, message: message) }
            throw fail(message)
        }
        session.start()

        self.session = session
        self.capture = capture
        state = .recording
    }

    func stop() async {
        guard state == .recording, let session, let capture else { return }
        let rest = capture.stop()
        let seconds = capture.recordedSeconds
        self.capture = nil
        // The audio session stays active until the text is on the clipboard: it is what keeps Kay running
        // in the background meanwhile.
        defer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

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
            let pasteboard = UIPasteboard.general
            let before = pasteboard.changeCount
            pasteboard.string = text
            let copied = pasteboard.changeCount != before
            Trace.log("pasteboard: changeCount \(before) -> \(pasteboard.changeCount), appState=\(UIApplication.shared.applicationState.rawValue)")
            record(HistoryEntry(date: Date(), text: text, audioSeconds: seconds, latencyMs: ms))
            if copied {
                await endActivity(.copied, message: text)
            } else {
                pendingCopy = text
                await endActivity(.tapToCopy, message: text)
            }
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

    /// Also kept in the history: from the control nothing of Kay is on screen, so this is the only place
    /// the reason shows up.
    private func fail(_ message: String) -> KayError {
        lastError = message
        Trace.log("start failed: \(message)")
        record(HistoryEntry(date: Date(), text: "", audioSeconds: 0, latencyMs: nil, error: message))
        return KayError(message: message)
    }

    // MARK: - Live Activity

    /// Required, not decoration: the system only lets an `AudioRecordingIntent` keep the microphone
    /// while a Live Activity is up.
    private func startActivity() {
        let state = DictationActivityAttributes.ContentState(phase: .listening, startedAt: startedAt, message: nil)
        do {
            activity = try Activity.request(attributes: DictationActivityAttributes(),
                                            content: .init(state: state, staleDate: nil))
            Trace.log("activity started")
        } catch {
            Trace.log("activity failed: \(error)")
        }
    }

    private func updateActivity(_ phase: DictationActivityAttributes.ContentState.Phase, message: String?) async {
        let state = DictationActivityAttributes.ContentState(phase: phase, startedAt: startedAt, message: message)
        await activity?.update(.init(state: state, staleDate: nil))
    }

    /// Leaves the result on the Lock Screen / Dynamic Island for a few seconds, then goes away.
    private func endActivity(_ phase: DictationActivityAttributes.ContentState.Phase, message: String) async {
        let state = DictationActivityAttributes.ContentState(phase: phase, startedAt: startedAt, message: message)
        let linger: TimeInterval = phase == .tapToCopy ? 60 : 4
        await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + linger))
        activity = nil
    }
}
