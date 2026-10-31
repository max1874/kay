import AppKit
import SwiftUI

/// What the main window shows beside its sidebar: your dictations, or one pane of Kay's settings. Settings has
/// no window of its own (Max, 2026-10-31: one window instead of two side by side).
enum Pane: String, Identifiable {
    case dictations, general, speech, correction

    static let settings: [Pane] = [.general, .speech, .correction]
    static let storageKey = "pane"
    /// The settings pane seen last, which Settings… (⌘,) opens again (HIG, Settings: restore the most recently
    /// viewed pane). The Settings window kept its tab here, so that choice carries over.
    private static let settingsKey = "settings.tab"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dictations: "Dictations"
        case .general: "General"
        case .speech: "Speech Service"
        case .correction: "Correction"
        }
    }

    var symbol: String {
        switch self {
        case .dictations: "text.bubble"
        case .general: "gearshape"
        case .speech: "waveform.badge.mic"
        case .correction: "text.badge.checkmark"
        }
    }

    /// Each pane its own colour, as in Lumo's Settings: a row is found at a glance rather than read.
    var tint: Color {
        switch self {
        case .dictations: .pink
        case .general: .gray
        case .speech: .purple
        case .correction: .teal
        }
    }

    /// Switches the main window to this pane; `show()` also brings the window up.
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        if self != .dictations { UserDefaults.standard.set(rawValue, forKey: Self.settingsKey) }
    }

    func show() {
        select()
        KayApp.showMainWindow()
    }

    static func showSettings() {
        (Pane(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "") ?? .general).show()
    }
}

/// One pane of Kay's settings. Each Form scrolls inside the window: sized to its content, as the Settings
/// window had them, they stretched the split view to 7947 pt and pushed the sidebar out of sight (1.5.8).
struct SettingsPane: View {
    let pane: Pane

    var body: some View {
        switch pane {
        case .dictations: EmptyView()
        case .general: GeneralSettings()
        case .speech: SpeechSettings()
        case .correction: CorrectionSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(AppModel.menuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(AppModel.dockIconKey) private var showDockIcon = true
    @AppStorage(AppModel.clipboardHistoryKey) private var showInClipboardHistory = true
    @AppStorage(MediaPause.defaultsKey) private var pauseMedia = true
    @AppStorage(Microphones.storageKey) private var microphoneUID = ""
    @State private var microphones: [Microphones.Device] = []
    @State private var defaultMicrophone: String?
    @State private var confirmClear = false

    private func reloadMicrophones() {
        microphones = Microphones.all()
        defaultMicrophone = Microphones.defaultName()
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                ForEach(model.triggers) { trigger in
                    LabeledContent(trigger.name) {
                        Button("Remove", systemImage: "minus.circle") {
                            model.triggers.removeAll { $0 == trigger }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(model.triggers.count == 1)
                    }
                }
                Button("Add Key…") { model.recordingTrigger = true }
            } header: {
                Text("Shortcut")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Holding any key in the list dictates, so each keyboard can use its own. Pressing any other key while you hold it cancels the recording, so shortcuts that use the same key keep working.")
                    if model.globeKeyConflict {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("If the emoji picker or another input source shows up after you let go of fn, set “Press 🌐 key to” to “Do Nothing”.")
                            Button("Keyboard Settings…", action: model.openKeyboardSettings)
                                .buttonStyle(.link)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            // Also in the main window, under the status line, for switching on the spot; Settings is where
            // Max looks for it (2026-10-08), so it lives in both, on the same stored choice.
            Section {
                Picker("Microphone", selection: $microphoneUID) {
                    Text(defaultMicrophone.map { String(localized: "System Default (\($0))") } ?? String(localized: "System Default"))
                        .tag("")
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    // A chosen microphone that is unplugged stays chosen, and listed, until it's back.
                    if !microphoneUID.isEmpty, !microphones.contains(where: { $0.uid == microphoneUID }) {
                        Text("Not Connected").tag(microphoneUID)
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("When the chosen microphone isn't connected, Kay records from the system default.")
                    .foregroundStyle(.secondary)
            }
            // Plugged in or out since: read when Settings shows and whenever Kay comes forward.
            .onAppear(perform: reloadMicrophones)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                reloadMicrophones()
            }

            Section {
                Toggle("Show in Clipboard History", isOn: $showInClipboardHistory)
            } header: {
                Text("Pasting")
            } footer: {
                Text("Kay pastes through the clipboard and then puts back what was there. When this is off, clipboard history apps such as Raycast leave dictations out.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause Music and Videos", isOn: $pauseMedia)
            } footer: {
                Text("While you dictate with the sound coming from speakers, Kay pauses what is playing and plays it again afterwards. With headphones it keeps playing.")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", symbol: "mic.fill", tint: .red,
                              granted: model.microphone == .authorized, action: model.requestMicrophone)
                PermissionRow(title: "Accessibility", symbol: "accessibility", tint: .blue,
                              granted: model.accessibility, action: model.openAccessibilitySettings)
            }

            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }))
                Toggle("Show in Menu Bar", isOn: $showMenuBarIcon)
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { AppModel.applyDockIcon(showDockIcon) }
                LabeledContent("History") {
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.url])
                        }
                        Button("Clear All…", role: .destructive) { confirmClear = true }
                    }
                    .disabled(model.history.isEmpty)
                }
                LabeledContent("Version") {
                    HStack {
                        Text(verbatim: version)
                        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    }
                }
            } header: {
                Text("App")
            } footer: {
                if !showDockIcon {
                    Text("Without a Dock icon Kay opens straight into the background at launch. Open Kay again from Spotlight or Applications to bring this window back.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This can't be undone.")
        }
        // Presented, keys pressed in Kay's windows don't dictate, so the ones being recorded don't.
        .sheet(isPresented: $model.recordingTrigger) {
            TriggerRecorder(existing: model.triggers) { model.triggers.append($0) }
        }
    }
}

/// Records a new trigger: the modifier keys pressed together, shown as they go down and kept once all are up,
/// so people see what macOS reports for a key. A key the keyboard keeps to itself shows nothing.
private struct TriggerRecorder: View {
    let existing: [Trigger]
    let add: (Trigger) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var down = Trigger()
    @State private var keys = Trigger()
    @State private var typedKey = false
    @State private var monitor: Any?

    private var recorded: Bool { down.isEmpty && !keys.isEmpty }
    private var duplicate: Bool { recorded && existing.contains(keys) }

    private var hint: LocalizedStringKey {
        if duplicate { return "This key is already in the list." }
        if typedKey { return "Only modifier keys can be held to dictate." }
        return "fn, Control, Option, Shift or Command, alone or together. Left and right are different keys."
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Press the Key to Hold")
                .font(.headline)
            Text(verbatim: keys.isEmpty ? "–" : keys.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(keys.isEmpty ? .tertiary : .primary)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add(keys); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!recorded || duplicate)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: record) }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            // Return and Escape still press Add and Cancel; any other key is not one that can be held.
            if down.isEmpty, [36, 53].contains(event.keyCode) { return event }
            keys = []
            typedKey = true
            return nil
        }
        let now = Trigger(after: event, from: down)
        if down.isEmpty, !now.isEmpty {
            keys = now
            typedKey = false
        } else {
            keys.formUnion(now)
        }
        down = now
        return event
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings", action: action)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint.gradient, in: .rect(cornerRadius: 5))
            }
        }
    }
}

// MARK: - Speech Service

/// Which service Kay dictates with, picked from a menu so the pane stays the same size however many there
/// are (Max, 2026-10-11: "what if there are 20"). Services with a key come first; picking one switches on
/// the spot, after a test if it hasn't passed one since launch. Picking one without a key shows its key form,
/// and it becomes the one dictation uses once its key passes the test; until then dictation stays where it
/// was, and the pane says so.
private struct SpeechSettings: View {
    @ObservedObject private var speech = SpeechService.shared
    /// The service whose key form is shown.
    @State private var shown = SpeechService.shared.provider
    @State private var draft = ""
    @State private var settingDraft = ""
    @State private var confirmRemove = false

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var status: SpeechService.Status { speech.status(of: shown) }
    private var hasKey: Bool { speech.hasKey(shown) }
    private var changed: Bool {
        !trimmedDraft.isEmpty || settingDraft.trimmingCharacters(in: .whitespacesAndNewlines) != speech.setting(of: shown)
    }

    var body: some View {
        Form {
            Section {
                Picker("Dictate With", selection: Binding(get: { shown }, set: { choose($0) })) {
                    let ready = SpeechProvider.allCases.filter { speech.hasKey($0) }
                    let notSet = SpeechProvider.allCases.filter { !speech.hasKey($0) }
                    ForEach(ready) { ProviderLabel(provider: $0).tag($0) }
                    if !ready.isEmpty && !notSet.isEmpty { Divider() }
                    ForEach(notSet) { ProviderLabel(provider: $0, notSet: true).tag($0) }
                }
                ProviderSummary(provider: shown, status: status)
                if shown != speech.provider {
                    Label("Kay keeps dictating with \(speech.provider.name) until this key passes the test.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Kay uses your own account with each service. Audio goes straight from this Mac to the one you choose, keys stay in the macOS Keychain, and each service bills you at its standard rates. You can also switch from the menu under the status line in Kay's window.")
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField(text: $draft, prompt: keyPrompt) { Text("API Key") }
                    .onSubmit(test)
                    .onChange(of: draft) { speech.clearCandidateError(of: shown) }
                switch shown {
                case .qwen:
                    TextField("Workspace URL", text: $settingDraft,
                              prompt: Text(verbatim: QwenSession.defaultWorkspaceURL))
                        .onSubmit(test)
                        .onChange(of: settingDraft) { speech.clearCandidateError(of: shown) }
                case .doubao:
                    Picker("Resource", selection: $settingDraft) {
                        ForEach(DoubaoSession.resources) { resource in
                            Text(verbatim: "\(resource.title) · \(resource.id)").tag(resource.id)
                        }
                    }
                    .onChange(of: settingDraft) { speech.clearCandidateError(of: shown) }
                }
                HStack(spacing: 12) {
                    Button(action: test) {
                        if status == .testing {
                            ProgressView().controlSize(.small)
                        } else if hasKey && !changed {
                            Text("Test Again")
                        } else {
                            Text("Test & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(status == .testing || (trimmedDraft.isEmpty && !hasKey))
                    StatusMessage(status: status, candidateError: speech.candidateError(of: shown))
                    Spacer(minLength: 0)
                }
            } header: {
                Text("API Key")
            } footer: {
                HStack(spacing: 14) {
                    Text(hint).foregroundStyle(.secondary)
                    Spacer()
                    Link("Get an API Key ↗", destination: shown.apiKeysURL)
                    Link(shown.consoleName, destination: shown.consoleURL)
                }
            }

            if hasKey {
                Section {
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { show(speech.provider) }
        .onChange(of: speech.provider) { show(speech.provider) }
        .confirmationDialog("Remove this key from Kay?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { speech.remove(shown) }
        } message: {
            switch shown {
            case .qwen: Text("It stays valid in Alibaba Cloud. If it was exposed, revoke it in the console.")
            case .doubao: Text("It stays valid in Volcengine. If it was exposed, revoke it in the console.")
            }
        }
    }

    private var keyPrompt: Text {
        if let masked = speech.maskedKey(of: shown) {
            Text("Saved (\(masked)). Paste a new key to replace it.")
        } else {
            switch shown {
            case .qwen: Text("Paste your Alibaba Cloud API Key")
            case .doubao: Text("Paste your Volcengine API Key")
            }
        }
    }

    private var hint: LocalizedStringKey {
        switch shown {
        case .qwen: "Alibaba Cloud Model Studio → API Key. Use the key and URL for the same workspace."
        case .doubao: "Volcengine console → Doubao Speech → API Key (new console)."
        }
    }

    private func choose(_ provider: SpeechProvider) {
        show(provider)
        speech.select(provider)
    }

    private func show(_ provider: SpeechProvider) {
        guard provider != shown || settingDraft.isEmpty else { return }
        shown = provider
        draft = ""
        settingDraft = speech.setting(of: provider)
    }

    private func test() {
        let provider = shown
        let key = trimmedDraft
        guard !key.isEmpty || speech.hasKey(provider) else { return }
        Task { @MainActor in
            await speech.test(provider, newKey: key.isEmpty ? nil : key, newSetting: settingDraft)
            guard case .connected = speech.status(of: provider), speech.candidateError(of: provider) == nil,
                  shown == provider else { return }
            draft = ""
            // A service set up here, and still the one picked, is the one the user wants to dictate with.
            speech.select(provider)
        }
    }
}

// MARK: - Correction

/// The switch and DeepSeek key for `Correction`. On by default; without a key it has nothing to run on.
private struct CorrectionSettings: View {
    @ObservedObject private var correction = Correction.shared
    @AppStorage(Correction.enabledKey) private var enabled = true
    @State private var draft = ""
    @State private var confirmRemove = false

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                Toggle("Fix Misheard Words", isOn: $enabled)
                if enabled && !correction.hasKey {
                    Label("Add a DeepSeek API key below to turn this on.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("After recognition, DeepSeek V4.1 Flash corrects words the speech service misheard, such as product names, without rewording what you said. It adds about half a second. If DeepSeek doesn't answer within 3 seconds, Kay pastes what it heard.")
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField(text: $draft, prompt: keyPrompt) { Text("API Key") }
                    .onSubmit(test)
                    .onChange(of: draft) { correction.clearCandidateError() }
                HStack(spacing: 12) {
                    Button(action: test) {
                        if correction.status == .testing {
                            ProgressView().controlSize(.small)
                        } else if correction.hasKey && trimmedDraft.isEmpty {
                            Text("Test Again")
                        } else {
                            Text("Test & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(correction.status == .testing || (trimmedDraft.isEmpty && !correction.hasKey))
                    CorrectionStatus(status: correction.status, candidateError: correction.candidateError)
                    Spacer(minLength: 0)
                }
            } header: {
                HStack {
                    Text("DeepSeek API Key")
                    Spacer()
                    StatusBadge(status: correction.status)
                }
            } footer: {
                HStack(spacing: 14) {
                    Text("DeepSeek Platform → API Keys. DeepSeek bills you at its standard rates.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Get an API Key ↗", destination: Correction.apiKeysURL)
                    Link("DeepSeek Platform", destination: Correction.consoleURL)
                }
            }

            if correction.hasKey {
                Section {
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }

            VocabularyEditor()
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this key from Kay?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { correction.remove() }
        } message: {
            Text("It stays valid in DeepSeek. If it was exposed, revoke it on the DeepSeek Platform.")
        }
    }

    private var keyPrompt: Text {
        if let masked = correction.maskedKey {
            Text("Saved (\(masked)). Paste a new key to replace it.")
        } else {
            Text("Paste your DeepSeek API Key")
        }
    }

    private func test() {
        let key = trimmedDraft
        guard !key.isEmpty || correction.hasKey else { return }
        Task { @MainActor in
            await correction.test(newKey: key.isEmpty ? nil : key)
            if case .connected = correction.status, correction.candidateError == nil { draft = "" }
        }
    }
}

/// The vocabulary file, edited in place; the next dictation uses it. It works without a DeepSeek key.
private struct VocabularyEditor: View {
    @State private var text = ""
    @State private var saved = ""
    @State private var failed = false

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 140)
                .onChange(of: text) { failed = false }
            HStack(spacing: 12) {
                if failed {
                    Label("Couldn't save the vocabulary.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("\(Vocabulary(parsing: text).terms.count) terms")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Vocabulary.url])
                }
                Button("Save") {
                    guard Vocabulary.save(text) else { failed = true; return }
                    saved = text
                }
                .buttonStyle(.borderedProminent)
                .disabled(text == saved)
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Names you spell your own way, one per line. Kay fixes them when they come back spelled out (c f → CF, e to b → E2B). If one is misheard as something else, add that after a bar: Raycast | 瑞卡斯特. # starts a comment.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            text = Vocabulary.text()
            saved = text
        }
    }
}

/// `StatusMessage` without the dictation wording.
private struct CorrectionStatus: View {
    let status: SpeechService.Status
    let candidateError: String?

    var body: some View {
        if let candidateError {
            Label {
                Text(verbatim: candidateError).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } else {
            switch status {
            case .connected(let ms):
                Label {
                    Text("Connected · \(ms) ms")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            case .failed(let message):
                Label {
                    Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            default:
                EmptyView()
            }
        }
    }
}

private struct ProviderSummary: View {
    let provider: SpeechProvider
    let status: SpeechService.Status

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.name).font(.headline)
                Text(verbatim: provider.model).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: status)
        }
    }
}

private struct StatusBadge: View {
    let status: SpeechService.Status

    var body: some View {
        let (label, tint): (LocalizedStringKey, Color) = switch status {
        case .notSet: ("Not Set", .gray)
        case .saved: ("Saved", .blue)
        case .testing: ("Testing…", .gray)
        case .connected: ("Connected", .green)
        case .failed: ("Failed", .red)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: .capsule)
    }
}

private struct StatusMessage: View {
    let status: SpeechService.Status
    let candidateError: String?

    var body: some View {
        if let candidateError {
            Label {
                Text(verbatim: candidateError).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } else {
            switch status {
            case .connected(let ms):
                Label {
                    Text("Connected · \(ms) ms. Ready to dictate.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            case .failed(let message):
                Label {
                    Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            default:
                EmptyView()
            }
        }
    }
}
