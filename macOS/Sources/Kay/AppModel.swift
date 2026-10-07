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
    /// Read by `@AppStorage` in the App and Settings; the model never observes it, since the scene
    /// that binds it must not depend on this object (1.2.0 looped rebuilding the menu bar that way).
    static let menuBarIconKey = "showMenuBarIcon"
    /// Off: no Dock icon, and no window at launch — Kay just waits for the key.
    static let dockIconKey = "showDockIcon"

    static var showsDockIcon: Bool {
        UserDefaults.standard.object(forKey: dockIconKey) as? Bool ?? true
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

    @Published private(set) var state = State.idle
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
    private var session: DoubaoSession?
    private var pressedAt = Date()
    private var poll: Timer?
    private var activation: NSObjectProtocol?
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
        hud.hide()
    }
}
