import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $model.pane) { pane in
                PaneRow(pane: pane).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(178)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.pane {
                case .home: HomePane()
                case .history: HistoryPane()
                case .speech: SpeechPane()
                case .general: GeneralPane()
                }
            }
            .navigationTitle(model.pane.title)
        }
    }
}

extension Pane {
    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .speech: "Speech Service"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .home: "waveform"
        case .history: "clock.arrow.circlepath"
        case .speech: "key.fill"
        case .general: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .home: .pink
        case .history: .orange
        case .speech: .purple
        case .general: .gray
        }
    }
}

/// A sidebar row: the symbol in a filled rounded square (Lumo's settings sidebar).
private struct PaneRow: View {
    let pane: Pane

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: pane.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5.5))
            Text(pane.title)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Home

private struct HomePane: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    StateGlyph(state: model.state, ready: model.isReady)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(.title3.weight(.semibold))
                        Text("Hold Right Option and speak. Let go, and the text appears where your cursor is.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Before You Start") {
                CheckRow(ok: model.microphone == .authorized, title: "Microphone",
                         detail: Text("Kay records only while you hold the key."),
                         actionTitle: "Allow", action: model.requestMicrophone)
                CheckRow(ok: model.accessibility, title: "Accessibility",
                         detail: Text("Lets Kay notice Right Option and paste the text for you."),
                         actionTitle: "Open Settings", action: model.openAccessibilitySettings)
                CheckRow(ok: speech.status.isUsable, title: "Speech Service",
                         detail: speech.status.summary(maskedKey: speech.maskedKey),
                         actionTitle: "Set Up", action: { model.pane = .speech })
            }

            Section("Usage") {
                HStack(spacing: 0) {
                    Stat(value: "\(model.todayCount)", label: "Dictations today")
                    Divider().frame(height: 36)
                    Stat(value: model.totalCharacters.formatted(), label: "Characters dictated")
                    Divider().frame(height: 36)
                    Stat(value: Format.duration(model.totalAudioSeconds), label: "Audio sent")
                }
                HStack {
                    Text("Counted on this Mac. Volcengine bills by audio length; your actual bill is in its console.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Link("Console ↗", destination: SpeechService.consoleURL).font(.callout)
                }
            }

            Section("Recent") {
                if model.history.isEmpty {
                    Text("Nothing yet. Hold Right Option and say something.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.history.prefix(5)) { entry in
                        HistoryRow(entry: entry)
                    }
                    Button("Show All History") { model.pane = .history }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var headline: LocalizedStringKey {
        switch model.state {
        case .recording: "Listening…"
        case .processing: "Recognizing…"
        case .idle: model.isReady ? "Ready" : "A few things to set up"
        }
    }
}

private struct StateGlyph: View {
    let state: AppModel.State
    let ready: Bool

    var body: some View {
        let (symbol, tint): (String, Color) = switch state {
        case .recording: ("mic.fill", .red)
        case .processing: ("ellipsis", .blue)
        case .idle: ready ? ("waveform", .pink) : ("exclamationmark", .orange)
        }
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CheckRow: View {
    let ok: Bool
    let title: LocalizedStringKey
    let detail: Text
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail.font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button(actionTitle, action: action)
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject private var model = AppModel.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var entries: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.history }
        return model.history.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No Dictations Yet", systemImage: "waveform",
                                       description: Text("Hold Right Option and say something."))
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry)
                            .contextMenu {
                                if entry.error == nil {
                                    Button("Copy") { model.copy(entry.text) }
                                }
                                Button("Delete", role: .destructive) { model.delete(entry) }
                            }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: Text("Search"))
        .toolbar {
            ToolbarItem {
                Button("Clear All…") { confirmClear = true }
                    .disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = entry.error {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else {
                    Text(verbatim: entry.text).textSelection(.enabled)
                }
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.error == nil {
                Button {
                    AppModel.shared.copy(entry.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(Text("Copy"))
            }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        var parts = [entry.date.formatted(date: .abbreviated, time: .shortened),
                     Format.duration(entry.audioSeconds)]
        if let ms = entry.latencyMs { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Speech Service

private struct SpeechPane: View {
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
                        .frame(width: 36, height: 36)
                        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volcengine Doubao").font(.headline)
                        Text("Streaming ASR 2.0 · sentence mode").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: speech.status)
                }
                Text("Kay uses your own Volcengine account. Audio goes straight from this Mac to Volcengine, your key stays in the macOS Keychain, and Volcengine bills you at its standard rates.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("API Key") {
                VStack(alignment: .leading, spacing: 5) {
                    SecureField(text: $draft, prompt: placeholder) { Text("API Key") }
                        .onSubmit(test)
                    Text("Volcengine console → Doubao Speech → API Key (new console).")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
                    Spacer()
                    Link("Get an API Key ↗", destination: SpeechService.apiKeysURL)
                    Link("Enable the Service ↗", destination: SpeechService.activateURL)
                }
                StatusMessage(status: speech.status)
            }

            if speech.hasKey {
                Section {
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }

            Section("Other Providers") {
                HStack {
                    Text("Alibaba Qwen ASR")
                    Spacer()
                    Text("Coming soon").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
            if case .connected = speech.status { draft = "" }
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

private struct StatusMessage: View {
    let status: SpeechService.Status

    var body: some View {
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

extension SpeechService.Status {
    func summary(maskedKey: String?) -> Text {
        switch self {
        case .notSet: Text("Add your Volcengine API key.")
        case .saved: Text("Key saved (\(maskedKey ?? "")).")
        case .testing: Text("Testing…")
        case .connected(let ms): Text("Connected · \(ms) ms")
        case .failed(let message): Text(verbatim: message)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var model = AppModel.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Shortcut") {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Hold to talk") {
                        Text("Right Option ⌥").foregroundStyle(.secondary)
                    }
                    Text("Pressing any other key while you hold it cancels the recording, so ⌥ shortcuts keep working.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", granted: model.microphone == .authorized,
                              action: model.requestMicrophone)
                PermissionRow(title: "Accessibility", granted: model.accessibility,
                              action: model.openAccessibilitySettings)
            }

            Section("App") {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }))
                Toggle("Show in Menu Bar", isOn: $model.showMenuBarIcon)
                LabeledContent("Version") { Text(verbatim: version).foregroundStyle(.secondary) }
                LabeledContent("History") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.url])
                    }
                    .disabled(model.history.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
            }
        }
    }
}

enum Format {
    /// "1 min 20 s" / "1 分钟 20 秒", in the system's language.
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds.rounded()) ?? "0s"
    }
}
