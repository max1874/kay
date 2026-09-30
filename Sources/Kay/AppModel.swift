import AppKit
import AVFoundation
import Combine
import ServiceManagement
import os

let log = Logger(subsystem: "com.max1874.kay", category: "app")

/// Dictation, permissions and history. Views observe it; the hotkey drives it.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum State { case idle, recording, processing }

    /// 按住不足这个时长视为误触，不识别。
    private static let minHold: TimeInterval = 0.3
    private static let menuBarIconKey = "showMenuBarIcon"
    /// How many recent levels the live waveform keeps.
    static let levelCount = 64

    @Published private(set) var state = State.idle
    @Published private(set) var history: [HistoryEntry] = []
    /// When the current dictation started; nil when idle.
    @Published private(set) var startedAt: Date?
    /// Recent input levels, oldest first, while recording.
    @Published private(set) var levels: [Float] = []
    /// The entry the last dictation produced, so the window can select it.
    @Published private(set) var latestEntryID: HistoryEntry.ID?
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published var showMenuBarIcon = UserDefaults.standard.object(forKey: AppModel.menuBarIconKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: Self.menuBarIconKey) }
    }

    let speech = SpeechService.shared
    private lazy var hud = HUD()
    private let hotkey = HotkeyMonitor()
    private var capture: AudioCapture?
    private var session: DoubaoSession?
    private var pressedAt = Date()
    private var poll: Timer?
    private var speechChanges: AnyCancellable?

    var isReady: Bool {
        microphone == .authorized && accessibility && speech.status.isUsable
    }

    func start() {
        history = HistoryStore.load()
        // `isReady` reads the speech status, so views watching only this model must hear about it too.
        speechChanges = speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        hotkey.onPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in self?.end() }
        hotkey.onInterrupt = { [weak self] in self?.cancel() }
        hotkey.start()

        if microphone == .notDetermined { requestMicrophone() }
        if !accessibility { promptAccessibility() }
        // Both grants happen in System Settings; checking once a second is what turns the rows
        // green without a relaunch, and what re-arms the hotkey once Accessibility arrives.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        if speech.hasKey {
            Task { await speech.test(newKey: nil) }
        }
    }

    private func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            if trusted {
                hotkey.start()
                log.notice("accessibility granted, hotkey monitor restarted")
            }
        }
    }

    // MARK: - Permissions

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshPermissions() }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func openAccessibilitySettings() {
        promptAccessibility()
        openPrivacyPane("Privacy_Accessibility")
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - History

    var todayCount: Int {
        history.filter { $0.error == nil && Calendar.current.isDateInToday($0.date) }.count
    }

    var totalCharacters: Int {
        history.reduce(0) { $0 + $1.spokenCharacters }
    }

    var totalAudioSeconds: Double {
        history.reduce(0) { $0 + $1.audioSeconds }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func delete(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history = []
        HistoryStore.save(history)
    }

    private func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        latestEntryID = entry.id
        if history.count > HistoryStore.limit { history.removeLast(history.count - HistoryStore.limit) }
        HistoryStore.save(history)
    }

    // MARK: - 按住说话

    private func begin() {
        guard state == .idle else { return }
        guard let apiKey = speech.apiKey else {
            hud.flash(String(localized: "No API key yet. Add one in Kay → Settings → Speech Service."),
                      symbol: "key.fill", seconds: 3)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash(String(localized: "Kay can't use the microphone. Allow it in System Settings."),
                      symbol: "mic.slash.fill", seconds: 3)
            return
        }

        let session = DoubaoSession(apiKey: apiKey, resourceId: speech.resourceId)
        let capture = AudioCapture()
        capture.onChunk = { [weak session] in session?.sendAudio($0) }
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.levels.append(level)
                if self.levels.count > Self.levelCount { self.levels.removeFirst(self.levels.count - Self.levelCount) }
                self.hud.level(level)
            }
        }
        do {
            try capture.start()
        } catch {
            hud.flash(String(localized: "The microphone didn't start: \(error.localizedDescription)"),
                      symbol: "mic.slash.fill", seconds: 3)
            return
        }
        session.start()

        self.session = session
        self.capture = capture
        pressedAt = Date()
        startedAt = pressedAt
        levels = []
        state = .recording
        hud.listen(since: pressedAt)
    }

    private func end() {
        guard state == .recording, let session, let capture else { return }
        let rest = capture.stop()
        let seconds = capture.recordedSeconds
        self.capture = nil

        if Date().timeIntervalSince(pressedAt) < Self.minHold {
            cancel()
            return
        }

        state = .processing
        hud.recognize()
        let releasedAt = Date()
        session.finish(lastChunk: rest) { [weak self] result in
            DispatchQueue.main.async {
                self?.deliver(result, audioSeconds: seconds, latency: Date().timeIntervalSince(releasedAt))
            }
        }
    }

    private func deliver(_ result: Result<String, Error>, audioSeconds: Double, latency: TimeInterval) {
        session = nil
        state = .idle
        startedAt = nil
        let ms = Int(latency * 1000)
        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            log.notice("final in \(ms, privacy: .public) ms, \(text.count, privacy: .public) chars")
            guard !text.isEmpty else {
                hud.flash(String(localized: "Didn't catch that."), symbol: "ear.trianglebadge.exclamationmark")
                return
            }
            record(HistoryEntry(date: Date(), text: text, audioSeconds: audioSeconds, latencyMs: ms))
            if AXIsProcessTrusted() {
                hud.hide()
                TextInserter.insert(text)
            } else {
                copy(text)
                hud.flash(String(localized: "Copied. Kay needs Accessibility permission to paste for you."),
                          symbol: "doc.on.clipboard", seconds: 3)
            }
        case .failure(let error):
            let message = error.localizedDescription
            log.error("recognition failed: \(message, privacy: .public)")
            if let kayError = error as? KayError, kayError.isAuthFailure {
                speech.markFailed(message)
            }
            record(HistoryEntry(date: Date(), text: "", audioSeconds: audioSeconds, latencyMs: nil, error: message))
            hud.flash(message, symbol: "exclamationmark.triangle.fill", seconds: 4)
        }
    }

    private func cancel() {
        _ = capture?.stop()
        capture = nil
        session?.cancel()
        session = nil
        state = .idle
        startedAt = nil
        hud.hide()
    }
}
