import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, speech

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
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(AppModel.menuBarIconKey) private var showMenuBarIcon = true

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

            Section("Permissions") {
                PermissionRow(title: "Microphone", symbol: "mic.fill", tint: .red,
                              granted: model.microphone == .authorized, action: model.requestMicrophone)
                PermissionRow(title: "Accessibility", symbol: "accessibility", tint: .blue,
                              granted: model.accessibility, action: model.openAccessibilitySettings)
            }

            Section("App") {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }))
                Toggle("Show in Menu Bar", isOn: $showMenuBarIcon)
                LabeledContent("History") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.url])
                    }
                    .disabled(model.history.isEmpty)
                }
                LabeledContent("Version") { Text(verbatim: version) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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

private struct SpeechSettings: View {
    @ObservedObject private var speech = SpeechService.shared
    @State private var draft = ""
    @State private var confirmRemove = false

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.blue.gradient, in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volcengine Doubao").font(.headline)
                        Text("Streaming ASR 2.0 · sentence mode").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: speech.status)
                }
            } footer: {
                Text("Kay uses your own Volcengine account. Audio goes straight from this Mac to Volcengine, your key stays in the macOS Keychain, and Volcengine bills you at its standard rates.")
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField(text: $draft, prompt: placeholder) { Text("API Key") }
                    .onSubmit(test)
                    .onChange(of: draft) { speech.clearCandidateError() }
                Picker("Resource", selection: $speech.resourceId) {
                    ForEach(SpeechService.resources) { resource in
                        Text(verbatim: "\(resource.title) · \(resource.id)").tag(resource.id)
                    }
                }
                HStack(spacing: 12) {
                    Button(action: test) {
                        if speech.status == .testing {
                            ProgressView().controlSize(.small)
                        } else if trimmedDraft.isEmpty && speech.hasKey {
                            Text("Test Again")
                        } else {
                            Text("Test & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(speech.status == .testing || (trimmedDraft.isEmpty && !speech.hasKey))
                    StatusMessage(status: speech.status, candidateError: speech.candidateError)
                    Spacer(minLength: 0)
                }
            } header: {
                Text("API Key")
            } footer: {
                HStack(spacing: 14) {
                    Text("Volcengine console → Doubao Speech → API Key (new console).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Get an API Key ↗", destination: SpeechService.apiKeysURL)
                    Link("Enable the Service ↗", destination: SpeechService.activateURL)
                }
            }

            if speech.hasKey {
                Section {
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }

            Section("Other Providers") {
                LabeledContent("Alibaba Qwen ASR") {
                    Text("Coming soon")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove this key from Kay?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { speech.remove() }
        } message: {
            Text("It stays valid in Volcengine. If it was exposed, revoke it in the console.")
        }
    }

    private var placeholder: Text {
        if let masked = speech.maskedKey {
            Text("Saved (\(masked)). Paste a new key to replace it.")
        } else {
            Text("Paste your Volcengine API Key")
        }
    }

    private func test() {
        let key = trimmedDraft
        guard !key.isEmpty || speech.hasKey else { return }
        Task { @MainActor in
            await speech.test(newKey: key.isEmpty ? nil : key)
            if case .connected = speech.status, speech.candidateError == nil { draft = "" }
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
