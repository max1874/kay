import AppKit
import SwiftUI

/// The main window does two things: says whether Kay can dictate, and gives back what you said.
/// One column: status and usage on top, then every dictation as a card, newest first.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var query = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [(title: String, items: [HistoryEntry])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? model.history : model.history.filter { $0.text.localizedStandardContains(q) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in (Format.day(day), grouped[day]!) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !searching {
                    StatusHeader()
                        .padding(.bottom, 16)
                }

                if model.history.isEmpty {
                    Text("No dictations yet. Hold \(model.trigger.name) and say something.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                } else if searching && sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    ForEach(sections, id: \.title) { section in
                        Text(verbatim: section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                        ForEach(section.items) { entry in
                            EntryCard(entry: entry)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("Kay")
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search Dictations"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Speech service, shortcut and permissions")
            }
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

// MARK: - Status

/// The key to hold, whether Kay is ready, and — until it is — what is missing.
private struct StatusHeader: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var speech = SpeechService.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                KeyCap(trigger: model.trigger, active: model.isReady, recording: model.state == .recording)
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.title.weight(.bold))
                    Text("Speak while you hold it. Let go, and the text appears where your cursor is, in any app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.isReady {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            speech.status.summary(maskedKey: speech.maskedKey)
                            Text(verbatim: "·")
                            Link("Volcengine Console", destination: SpeechService.consoleURL)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.isReady {
                VStack(spacing: 10) {
                    SetupCard(done: model.microphone == .authorized, symbol: "mic.fill", tint: .red,
                              title: "Microphone", detail: Text("Kay records only while you hold the key."),
                              action: "Allow", perform: model.requestMicrophone)
                    SetupCard(done: model.accessibility, symbol: "accessibility", tint: .blue,
                              title: "Accessibility",
                              detail: Text("Lets Kay notice the dictation key and paste the text for you."),
                              action: "Open System Settings", perform: model.openAccessibilitySettings)
                    SetupCard(done: speech.status.isUsable, symbol: "key.fill", tint: .purple,
                              title: "Speech Service", detail: speech.status.summary(maskedKey: speech.maskedKey),
                              action: "Add API Key") {
                        settingsTab = .speech
                        openSettings()
                    }
                }
            }

            HStack(spacing: 12) {
                StatTile(value: "\(model.todayCount)", label: "Dictations Today", symbol: "text.bubble")
                StatTile(value: model.totalCharacters.formatted(), label: "Characters", symbol: "character.cursor.ibeam")
                StatTile(value: Format.duration(model.totalAudioSeconds), label: "Audio Sent", symbol: "waveform")
            }
        }
    }

    private var headline: LocalizedStringKey {
        switch model.state {
        case .recording: "Listening…"
        case .processing: "Recognizing…"
        case .idle: model.isReady ? "Hold \(model.trigger.name) to Dictate" : "Finish Setting Up Kay"
        }
    }
}

/// The key you hold, drawn as the keycap on a Mac keyboard.
private struct KeyCap: View {
    let trigger: Trigger
    let active: Bool
    let recording: Bool

    private var tint: Color? {
        if recording { return Color.red.opacity(0.35) }
        return active ? Color.pink.opacity(0.2) : nil
    }

    var body: some View {
        Group {
            switch trigger {
            case .fn:
                // fn top right, 🌐 bottom left, as printed on the key.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "fn")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer(minLength: 0)
                    Image(systemName: "globe")
                        .font(.system(size: 18, weight: .regular))
                }
            case .rightOption:
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: "⌥")
                        .font(.system(size: 22, weight: .regular))
                    Text(verbatim: "option")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(11)
        .frame(width: 76, height: 76)
        .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 15))
        .animation(.smooth(duration: 0.2), value: recording)
    }
}

private struct SetupCard: View {
    let done: Bool
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: Text
    let action: LocalizedStringKey
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                detail.font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button(action, action: perform)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}

private struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}

// MARK: - A dictation

/// Click to copy; copy and delete also appear on hover. Failed ones say why.
private struct EntryCard: View {
    let entry: HistoryEntry
    @ObservedObject private var model = AppModel.shared
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = entry.error {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: entry.text)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute())
                    Text(verbatim: Format.clock(entry.audioSeconds))
                        .monospacedDigit()
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if entry.error == nil {
                    Button("Copy", systemImage: "doc.on.doc", action: copy)
                }
                Button("Delete", systemImage: "trash") { model.delete(entry) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(14)
        .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary),
                    in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .onHover { hovering = $0 }
        .onTapGesture { if entry.error == nil { copy() } }
        .contextMenu {
            if entry.error == nil {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(entry) }
        }
        .animation(.smooth(duration: 0.15), value: hovering)
    }

    private func copy() {
        model.copy(entry.text)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

// MARK: - Shared

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

enum Format {
    /// "1 min 20 s" / "1分钟20秒", in the system's language.
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds.rounded()) ?? "0s"
    }

    /// "0:07", "12:30".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Section titles: Today, Yesterday, then dates.
    static func day(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.month().day().weekday() : .dateTime.year().month().day())
    }
}
