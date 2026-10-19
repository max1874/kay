import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, speech, correction

    /// Shared with Home, whose "Add API Key" opens Settings on the Speech Service tab.
    static let storageKey = "settings.tab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SpeechSettings()
                .tabItem { Label("Speech Service", systemImage: "waveform.badge.mic") }
                .tag(SettingsTab.speech)
            CorrectionSettings()
                .tabItem { Label("Correction", systemImage: "text.badge.checkmark") }
                .tag(SettingsTab.correction)
        }
        .frame(width: 560)
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
                Picker("Hold to talk", selection: $model.trigger) {
                    Text("fn (🌐)").tag(Trigger.fn)
                    Text("Right Option ⌥").tag(Trigger.rightOption)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pressing any other key while you hold it cancels the recording, so shortcuts that use the same key keep working.")
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
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This can't be undone.")
        }
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
        .fixedSize(horizontal: false, vertical: true)
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
        .fixedSize(horizontal: false, vertical: true)
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
