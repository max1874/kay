import AppKit
import AVFoundation
import Combine
import CoreAudio
import ServiceManagement

/// Dictation, permissions and history. Views observe it; the hotkey drives it.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum State { case idle, recording, processing }

    /// 按住不足这个时长视为误触，不识别。
    private static let minHold: TimeInterval = 0.3
    /// How long a microphone gets to start before the next one is tried. A wired or built-in one takes under
    /// 100 ms (500 ms for the Studio Display's); a Bluetooth headset first has to switch profiles.
    private static let microphoneTimeout: TimeInterval = 2
    private static let bluetoothMicrophoneTimeout: TimeInterval = 8
    /// Read by `@AppStorage` in the App and Settings; the model never observes it, since the scene
    /// that binds it must not depend on this object (1.2.0 looped rebuilding the menu bar that way).
    static let menuBarIconKey = "showMenuBarIcon"
    /// Off: no Dock icon, and no window at launch — Kay just waits for the key.
    static let dockIconKey = "showDockIcon"

    static var showsDockIcon: Bool {
        UserDefaults.standard.object(forKey: dockIconKey) as? Bool ?? true
    }

    /// Off: the text Kay pastes is marked so clipboard history apps (Raycast, Maccy, Paste) leave it out.
    static let clipboardHistoryKey = "showInClipboardHistory"

    static var showsInClipboardHistory: Bool {
        UserDefaults.standard.object(forKey: clipboardHistoryKey) as? Bool ?? true
    }

    static func applyDockIcon(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Leaving .regular deactivates the app; the window the change was made in stays in front.
        NSApp.activate()
    }

    /// With the Dock icon off, Kay still turned into a regular app with a Dock icon once one of its windows
    /// had been opened, and stayed that way after it closed (1.5.4, 2026-10-07: Foreground with showDockIcon
    /// off; nothing in Kay sets .regular except the toggle). Whatever does it, the setting wins again as soon
    /// as no window of Kay's is left on screen.
    static func hideDockIconIfWindowless() {
        guard !showsDockIcon, NSApp.activationPolicy() != .accessory else { return }
        // Titled windows only: the HUD is a borderless panel and the menu bar item has its own window.
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @Published private(set) var state = State.idle {
        didSet { if state == .idle { HangWatchdog.shared.disarm() } }
    }
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published var trigger = Trigger(rawValue: UserDefaults.standard.string(forKey: Trigger.defaultsKey) ?? "") ?? .fn {
        didSet {
            guard trigger != oldValue else { return }
            UserDefaults.standard.set(trigger.rawValue, forKey: Trigger.defaultsKey)
            hotkey.trigger = trigger
            refreshGlobeKey()
        }
    }
    /// fn is also the 🌐 key. Kay is held, and macOS's own 🌐 action is for a tap, so this is not a
    /// requirement; Settings only mentions it, for Macs where letting go still brings up the emoji picker.
    @Published private(set) var globeKeyConflict = false

    let speech = SpeechService.shared
    private lazy var hud = HUD()
    private let hotkey = HotkeyMonitor()
    private var capture: AudioCapture?
    private var session: SpeechSession?
    /// The audio of the dictation in progress, until its outcome is in history.
    private var pending: PendingDictation?
    private var pressedAt = Date()
    /// The microphone the dictation in progress records from, for its history entry.
    private var recordingFrom: String?
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var speechChanges: AnyCancellable?

    var isReady: Bool {
        microphone == .authorized && accessibility && speech.status.isUsable
    }

    func start() {
        let info = Bundle.main.infoDictionary
        log.notice("Kay \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) started")
        history = HistoryStore.load()
        // `isReady` reads the speech status, so views watching only this model must hear about it too.
        speechChanges = speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        hotkey.onPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in self?.end() }
        hotkey.onInterrupt = { [weak self] in self?.cancel() }
        hotkey.trigger = trigger
        hotkey.start()
        refreshGlobeKey()

        if microphone == .notDetermined { requestMicrophone() }
        if !accessibility { promptAccessibility() }
        pollWhileMissing()
        // Coming back to Kay (after System Settings, say) is when a changed grant or 🌐 setting matters.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
            self?.pollWhileMissing()
        }
        if speech.hasKey {
            Task { await speech.test(newKey: nil) }
        }
        // Reads its key from the Keychain now, not during the first dictation.
        _ = Correction.shared
        recoverLeftovers()
    }

    /// Both grants happen in System Settings; checking once a second is what turns the rows green without a
    /// relaunch, and what re-arms the hotkey once Accessibility arrives. Only until both are there: idle,
    /// Kay should not wake up at all.
    private func pollWhileMissing() {
        guard poll == nil, microphone != .authorized || !accessibility else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.refreshPermissions()
            if self.microphone == .authorized, self.accessibility {
                timer.invalidate()
                self.poll = nil
            }
        }
    }

    private func refreshPermissions() {
        refreshGlobeKey()
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

    /// `AppleFnUsageType` in com.apple.HIToolbox: 0 Do Nothing, 1 Change Input Source,
    /// 2 Show Emoji & Symbols, 3 Start Dictation. Missing means the system default, which is not 0.
    private func refreshGlobeKey() {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int
        let conflict = trigger == .fn && usage != 0
        if conflict != globeKeyConflict { globeKeyConflict = conflict }
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
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
                log.error("launch at login: \(error.localizedDescription)")
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
        PendingDictation.forget(entry.id)
    }

    func clearHistory() {
        history = []
        HistoryStore.save(history)
        PendingDictation.forgetAll()
    }

    private func record(_ entry: HistoryEntry) {
        // By date: a recovered dictation (see recoverLeftovers) is older than the ones after it.
        history.insert(entry, at: history.firstIndex { $0.date < entry.date } ?? history.count)
        if history.count > HistoryStore.limit { history.removeLast(history.count - HistoryStore.limit) }
        HistoryStore.save(history)
    }

    // MARK: - 按住说话

    private func begin() {
        guard state == .idle else { return }
        guard let session = speech.makeSession() else {
            hud.flash(String(localized: "No API key yet. Add one in Kay → Settings → Speech Service."),
                      symbol: "key.fill", seconds: 3)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash(String(localized: "Kay can't use the microphone. Allow it in System Settings."),
                      symbol: "mic.slash.fill", seconds: 3)
            return
        }

        // Until the dictation is over; `state` disarms it on the way back to idle, and the defer when it never starts.
        HangWatchdog.shared.arm()
        defer { if state == .idle { HangWatchdog.shared.disarm() } }
        // The hold counts from the key, not from the microphone being ready: a key let go while a slow start
        // was waited for is a dictation to recognize (or report as not caught), not a mistap to drop silently.
        let pressed = Date()

        let pending = PendingDictation()
        // The chosen microphone (or the system default), then the Mac's own if that one doesn't start.
        var microphones: [(id: AudioDeviceID, name: String)] = []
        if let first = Microphones.chosen() ?? Microphones.systemDefault() { microphones.append(first) }
        if let builtIn = Microphones.builtIn(), !microphones.contains(where: { $0.id == builtIn.id }) {
            microphones.append(builtIn)
        }
        log.notice("key down (\(session.provider.rawValue)); microphones to try: \(microphones.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")); system default: \(Microphones.defaultName() ?? "none")")

        var started: AudioCapture?
        var failure: Error = KayError(message: String(localized: "No microphone input is available."))
        for microphone in microphones {
            let capture = AudioCapture()
            capture.onChunk = { [weak session] in
                session?.sendAudio($0)
                pending?.append($0)
            }
            capture.onLevel = { [weak self] level in
                DispatchQueue.main.async {
                    guard let self, self.state == .recording else { return }
                    self.hud.level(level)
                }
            }
            let t = Date()
            do {
                try capture.start(device: microphone.id, timeout: Microphones.isBluetooth(microphone.id)
                                    ? Self.bluetoothMicrophoneTimeout : Self.microphoneTimeout)
                log.notice("recording from \(microphone.name), started in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                started = capture
                recordingFrom = microphone.name
                break
            } catch {
                failure = error
                log.error("\(microphone.name) didn't start after \(Int(Date().timeIntervalSince(t) * 1000)) ms: \(error.localizedDescription)")
            }
        }
        guard let capture = started else {
            pending?.discard()
            hud.flash(String(localized: "The microphone didn't start: \(failure.localizedDescription)"),
                      symbol: "mic.slash.fill", seconds: 3)
            return
        }
        session.start()

        self.session = session
        self.capture = capture
        self.pending = pending
        pressedAt = pressed
        state = .recording
        hud.listen()
    }

    private func end() {
        guard state == .recording, let session, let capture else { return }
        let rest = capture.stop()
        pending?.append(rest)
        let seconds = capture.recordedSeconds
        self.capture = nil

        let held = Date().timeIntervalSince(pressedAt)
        if held < Self.minHold {
            log.notice("key up after \(Int(held * 1000)) ms: too short")
            cancel()
            return
        }
        log.notice("key up after \(String(format: "%.1f", held)) s, \(String(format: "%.1f", seconds)) s of audio")

        state = .processing
        hud.recognize()
        let releasedAt = Date()
        let engine = session.provider
        let microphone = recordingFrom
        weak var dictation = session
        session.finish(lastChunk: rest, timeout: 10) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                func deliver(_ result: Result<String, Error>, heard: String? = nil, correctionMs: Int? = nil) {
                    self.deliver(result, engine: engine, microphone: microphone, audioSeconds: seconds,
                                 latency: Date().timeIntervalSince(releasedAt), heard: heard, correctionMs: correctionMs)
                }
                // Still processing, so the HUD keeps showing recognition and a quit waits for the paste.
                guard case .success(let raw) = result else { return deliver(result) }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return deliver(result) }
                // Your vocabulary before DeepSeek, so it reads "CF" rather than "c f"; and again on its answer, which
                // may have re-spaced a term (TypeWhisper runs its corrections on both sides for the same reason).
                let vocabulary = Vocabulary.current()
                let replacements = vocabulary.replacements(in: text)
                let replaced = vocabulary.apply(replacements, to: text)
                if !replacements.isEmpty { log.notice("vocabulary: \(replacements.count) replaced") }
                Correction.shared.correct(replaced) { corrected, ms in
                    // Cancelled meanwhile, like a session cancelled before its result. By identity, not by state:
                    // after a cancel the next dictation may be processing, and its audio and paste are its own.
                    guard self.state == .processing, let current = self.session, current === dictation else {
                        return log.notice("correction for a cancelled dictation dropped")
                    }
                    let final = vocabulary.apply(to: corrected ?? replaced)
                    guard final != text else { return deliver(result, correctionMs: ms) }
                    deliver(.success(final), heard: text, correctionMs: ms)
                }
            }
        }
    }

    private func deliver(_ result: Result<String, Error>, engine: SpeechProvider, microphone: String?, audioSeconds: Double,
                         latency: TimeInterval, heard: String? = nil, correctionMs: Int? = nil) {
        session = nil
        state = .idle
        // Only after the outcome is recorded below: a crash before that leaves the audio to recover.
        let pending = self.pending
        self.pending = nil
        var recorded: UUID?
        defer {
            if let recorded { pending?.keep(as: recorded) } else { pending?.discard() }
        }
        let ms = Int(latency * 1000)
        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            log.notice("final in \(ms) ms, \(text.count) chars")
            guard !text.isEmpty else {
                hud.flash(String(localized: "Didn't catch that."), symbol: "ear.trianglebadge.exclamationmark")
                return
            }
            let entry = HistoryEntry(date: Date(), text: text, audioSeconds: audioSeconds, latencyMs: ms,
                                     engine: engine.rawValue, microphone: microphone, heard: heard,
                                     correctionMs: correctionMs)
            record(entry)
            recorded = entry.id
            if AXIsProcessTrusted() {
                hud.hide()
                TextInserter.insert(text, inClipboardHistory: Self.showsInClipboardHistory)
            } else {
                copy(text)
                hud.flash(String(localized: "Copied. Kay needs Accessibility permission to paste for you."),
                          symbol: "doc.on.clipboard", seconds: 3)
            }
        case .failure(let error):
            let message = error.localizedDescription
            log.error("recognition failed (\(engine.rawValue)): \(message)\((error as? KayError)?.detail.map { " [\($0)]" } ?? "")")
            if let kayError = error as? KayError, kayError.isAuthFailure {
                speech.markFailed(message, provider: engine)
            }
            let entry = HistoryEntry(date: Date(), text: "", audioSeconds: audioSeconds, latencyMs: nil, error: message,
                                     engine: engine.rawValue, microphone: microphone)
            record(entry)
            recorded = entry.id
            hud.flash(message, symbol: "exclamationmark.triangle.fill", seconds: 4)
        }
    }

    private func cancel() {
        if state != .idle { log.notice("dictation cancelled") }
        _ = capture?.stop()
        capture = nil
        pending?.discard()
        pending = nil
        session?.cancel()
        session = nil
        state = .idle
        hud.hide()
    }

    // MARK: - Dictations a previous run didn't finish

    /// See `PendingDictation`. Oldest first, one at a time, into history without pasting.
    private func recoverLeftovers() {
        guard speech.hasKey else { return }
        recover(PendingDictation.leftovers()[...])
    }

    private func recover(_ leftovers: ArraySlice<(url: URL, started: Date)>) {
        guard let first = leftovers.first else { return }
        let (url, started) = (first.url, first.started)
        let next = leftovers.dropFirst()
        guard let pcm = try? Data(contentsOf: url), !pcm.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            recover(next)
            return
        }
        guard let session = speech.makeSession() else { return }
        let engine = session.provider
        session.start()
        // The same 200 ms packets a live dictation sends, only without waiting between them.
        var offset = 0
        while pcm.count - offset > AudioCapture.chunkBytes {
            session.sendAudio(pcm.subdata(in: offset..<offset + AudioCapture.chunkBytes))
            offset += AudioCapture.chunkBytes
        }
        let seconds = Double(pcm.count) / (16000 * 2)
        session.finish(lastChunk: pcm.subdata(in: offset..<pcm.count), timeout: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let raw):
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    log.notice("recovered an unfinished dictation of \(seconds) s: \(text.count) chars")
                    if !text.isEmpty {
                        let entry = HistoryEntry(date: started, text: text, audioSeconds: seconds, latencyMs: nil,
                                                 engine: engine.rawValue)
                        self.record(entry)
                        PendingDictation.keep(url, as: entry.id)
                        self.hud.flash(String(localized: "Recovered a dictation Kay didn't finish. It's in History."),
                                       symbol: "arrow.uturn.backward.circle", seconds: 3)
                    }
                    try? FileManager.default.removeItem(at: url)
                case .failure(let error):
                    // Kept for the next launch: no network yet at login is the usual reason.
                    log.error("unfinished dictation not recovered yet: \(error.localizedDescription)")
                }
                self.recover(next)
            }
        }
    }
}
