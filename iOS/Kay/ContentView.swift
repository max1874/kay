import SwiftUI

struct ContentView: View {
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var speech = SpeechService.shared
    @State private var draft = ""
    @State private var copiedID: HistoryEntry.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DictateButton()
                } footer: {
                    Text("Press the Action Button (or the Kay control) to start, press again to stop. The text is copied — paste it anywhere.")
                }

                Section("Action Button") {
                    Label("Settings → Action Button → Controls", systemImage: "1.circle")
                    Label("Choose “Dictate with Kay”", systemImage: "2.circle")
                    Label("Also available in Control Center and on the Lock Screen", systemImage: "3.circle")
                }

                Section {
                    SecureField(text: $draft, prompt: placeholder) { Text("API Key") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft) { speech.clearCandidateError() }
                    Picker("Resource", selection: $speech.resourceId) {
                        ForEach(SpeechService.resources) { resource in
                            Text(resource.title).tag(resource.id)
                        }
                    }
                    Button {
                        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await speech.test(newKey: key.isEmpty ? nil : key)
                            if case .connected = speech.status, speech.candidateError == nil { draft = "" }
                        }
                    } label: {
                        HStack {
                            Text(draft.isEmpty && speech.hasKey ? "Test Again" : "Test & Save")
                            Spacer()
                            if speech.status == .testing { ProgressView() }
                        }
                    }
                    .disabled(speech.status == .testing || (draft.isEmpty && !speech.hasKey))
                    if let message = speech.candidateError ?? failure {
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else if case .connected(let ms) = speech.status {
                        Label("Connected · \(ms) ms", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                } header: {
                    Text("Volcengine Doubao")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kay uses Doubao Streaming ASR 2.0 with your own Volcengine key. Create one in the console and make sure the service is enabled. The key stays in the Keychain; audio goes straight to Volcengine.")
                        HStack(spacing: 16) {
                            Link("Get an API Key ↗", destination: SpeechService.apiKeysURL)
                            Link("Enable the Service ↗", destination: SpeechService.activateURL)
                        }
                    }
                }

                Section("History") {
                    if dictation.history.isEmpty {
                        Text("No dictations yet.").foregroundStyle(.secondary)
                    }
                    ForEach(dictation.history) { entry in
                        Button {
                            guard entry.error == nil else { return }
                            dictation.copy(entry)
                            copiedID = entry.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let error = entry.error {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                } else {
                                    Text(entry.text).foregroundStyle(.primary)
                                }
                                HStack {
                                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                                    if copiedID == entry.id {
                                        Label("Copied", systemImage: "checkmark").foregroundStyle(.green)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { dictation.delete(entry) }
                        }
                    }
                }
            }
            .navigationTitle("Kay")
        }
    }

    private var placeholder: Text {
        if let masked = speech.maskedKey {
            Text("Saved (\(masked))")
        } else {
            Text("Paste your API key")
        }
    }

    private var failure: String? {
        if case .failed(let message) = speech.status { return message }
        return nil
    }
}

/// Start/stop inside the app: the same path the Action Button takes.
private struct DictateButton: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task { try? await dictation.toggle() }
            } label: {
                Image(systemName: dictation.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 76, height: 76)
            }
            .modifier(ProminentCircle())
            .tint(dictation.state == .recording ? .red : .accentColor)
            .disabled(dictation.state == .recognizing)

            Text(status)
                .font(.callout)
                .foregroundStyle(dictation.lastError == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var status: String {
        if let error = dictation.lastError { return error }
        switch dictation.state {
        case .idle: return String(localized: "Tap to dictate")
        case .recording: return String(localized: "Listening… tap to stop")
        case .recognizing: return String(localized: "Recognizing…")
        }
    }
}

/// Liquid Glass on iOS 26, the plain prominent style before it.
private struct ProminentCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
        }
    }
}
