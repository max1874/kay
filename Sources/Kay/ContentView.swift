import AppKit
import AVFoundation
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case entry(HistoryEntry.ID)
}

/// The main window: dictations in the sidebar, and on the right whichever one is selected,
/// the live recording while you hold the key, or Home.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
                .animation(.smooth(duration: 0.3), value: model.state)
        }
        .navigationTitle("Kay")
        .frame(minWidth: 760, minHeight: 500)
        .toolbar { KayToolbar(state: model.state, isReady: model.isReady, trigger: model.trigger, selection: $selection) }
        .onChange(of: model.latestEntryID) { _, id in
            if let id { selection = .entry(id) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.state != .idle {
            LiveView()
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if case .entry(let id)? = selection, let entry = model.history.first(where: { $0.id == id }) {
            EntryDetail(entry: entry, selection: $selection)
                .id(entry.id)
                .transition(.opacity)
        } else {
            HomeView()
                .transition(.opacity)
        }
    }
}

// MARK: - Toolbar

private struct KayToolbar: ToolbarContent {
    let state: AppModel.State
    let isReady: Bool
    let trigger: Trigger
    @Binding var selection: SidebarItem?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if state == .recording {
                Label("Listening", systemImage: "mic.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
            } else if !isReady {
                Button {
                    selection = .home
                } label: {
                    Label("Finish Setup", systemImage: "exclamationmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .tint(.orange)
                .buttonStyle(.borderedProminent)
                .help("Kay needs a few things before it can dictate")
            } else {
                Label {
                    Text("Hold \(trigger.name) to Talk")
                } icon: {
                    Image(systemName: "waveform")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Speech service, shortcut and permissions")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject private var model = AppModel.shared
    @Binding var selection: SidebarItem?
    @State private var query = ""

    private var sections: [(title: String, items: [HistoryEntry])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? model.history : model.history.filter { $0.text.localizedStandardContains(q) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (Format.day(day), grouped[day]!)
        }
    }

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(SidebarItem.home)

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { entry in
                        EntryRow(entry: entry)
                            .tag(SidebarItem.entry(entry.id))
                            .contextMenu { contextMenu(for: entry) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: Text("Search Dictations"))
        .onDeleteCommand {
            if case .entry(let id)? = selection, let entry = model.history.first(where: { $0.id == id }) {
                delete(entry)
            }
        }
        .overlay {
            if model.history.isEmpty {
                Text("No Dictations Yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if !query.isEmpty && sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        if entry.error == nil {
            Button("Copy", systemImage: "doc.on.doc") { model.copy(entry.text) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
    }

    private func delete(_ entry: HistoryEntry) {
        if selection == .entry(entry.id) {
            let items = model.history
            let index = items.firstIndex(of: entry) ?? 0
            let neighbor = items.indices.contains(index + 1) ? items[index + 1] : (index > 0 ? items[index - 1] : nil)
            selection = neighbor.map { SidebarItem.entry($0.id) } ?? .home
        }
        model.delete(entry)
    }
}

private struct EntryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = entry.error {
                Label {
                    Text(verbatim: error).lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.body)
            } else {
                Text(verbatim: entry.text)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute())
                Text(verbatim: Format.clock(entry.audioSeconds))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Home

private struct HomeView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var speech = SpeechService.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 18) {
                    KeyCap(trigger: model.trigger, active: model.isReady)
                    VStack(spacing: 8) {
                        Text(model.isReady ? LocalizedStringKey("Hold \(model.trigger.name) to Dictate") : "Finish Setting Up Kay")
                            .font(.largeTitle.weight(.bold))
                        Text("Speak while you hold it. Let go, and the text appears where your cursor is, in any app.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 12)

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
            .padding(40)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The key you hold, drawn as the keycap on a Mac keyboard.
private struct KeyCap: View {
    let trigger: Trigger
    let active: Bool

    var body: some View {
        Group {
            switch trigger {
            case .fn:
                // fn top right, 🌐 bottom left, as printed on the key.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "fn")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer(minLength: 0)
                    Image(systemName: "globe")
                        .font(.system(size: 22, weight: .regular))
                }
            case .rightOption:
                VStack(alignment: .trailing, spacing: 10) {
                    Text(verbatim: "⌥")
                        .font(.system(size: 30, weight: .regular))
                    Text(verbatim: "option")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(14)
        .frame(width: 96, height: 96)
        .glassEffect(.regular.tint(active ? Color.pink.opacity(0.25) : nil), in: .rect(cornerRadius: 18))
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
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }
}

private struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }
}

// MARK: - A dictation

private struct EntryDetail: View {
    let entry: HistoryEntry
    @Binding var selection: SidebarItem?
    @ObservedObject private var model = AppModel.shared
    @State private var copied = false

    private var meta: String {
        var parts = [Format.clock(entry.audioSeconds)]
        if entry.error == nil {
            parts.append(String(localized: "\(entry.spokenCharacters) characters"))
        }
        if let ms = entry.latencyMs {
            parts.append(String(localized: "recognized in \(ms) ms"))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.date.formatted(date: .complete, time: .shortened))
                        .font(.title.weight(.bold))
                    Text(verbatim: meta)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if let error = entry.error {
                        Label {
                            Text(verbatim: error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.title3)
                        .padding(.top, 24)
                    } else {
                        Text(verbatim: entry.text)
                            .font(.system(size: 20))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .padding(.top, 24)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.vertical, 32)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    if entry.error == nil {
                        Button {
                            model.copy(entry.text)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            Label(copied ? LocalizedStringKey("Copied") : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Copy (⇧⌘C)")
                    }
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Delete")
                }
                .controlSize(.large)
            }
            .padding(.bottom, 28)
        }
    }

    private func delete() {
        let items = model.history
        let index = items.firstIndex(of: entry) ?? 0
        let neighbor = items.indices.contains(index + 1) ? items[index + 1] : (index > 0 ? items[index - 1] : nil)
        selection = neighbor.map { SidebarItem.entry($0.id) } ?? .home
        model.delete(entry)
    }
}

// MARK: - Live

private struct LiveView: View {
    @ObservedObject private var model = AppModel.shared

    private var microphoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "Microphone")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text(verbatim: microphoneName)
                Text(verbatim: "→").foregroundStyle(.secondary)
                Image(systemName: "waveform.badge.mic")
                Text("Volcengine Doubao")
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Group {
                if let startedAt = model.startedAt, model.state == .recording {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(verbatim: Format.clock(context.date.timeIntervalSince(startedAt)))
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .font(.system(size: 72, weight: .light, design: .rounded))
            .monospacedDigit()
            .frame(height: 96)
            .padding(.top, 28)

            LevelBars(levels: model.levels, tint: model.state == .recording ? .red : .secondary)
                .frame(width: CGFloat(AppModel.levelCount) * 7, height: 110)
                .padding(.top, 20)

            Text(model.state == .recording
                 ? LocalizedStringKey("Let go of \(model.trigger.name) to finish. Press any other key to cancel.")
                 : "Recognizing…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Sidebar section titles: Today, Yesterday, then dates.
    static func day(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.month().day().weekday() : .dateTime.year().month().day())
    }
}
