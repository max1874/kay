import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var audioSeconds: Double
    var latencyMs: Int?
    /// Set when recognition failed; `text` is empty then.
    var error: String?
    /// The `SpeechProvider` that recognized it; nil before 1.7, when it was always one provider.
    var engine: String? = nil
    /// The microphone it was recorded from, by name; nil before 1.8 and for dictations recovered at launch.
    var microphone: String? = nil
    /// What the recognizer heard, when correction after recognition changed it; `text` is what was pasted.
    var heard: String? = nil
    /// How long correction took, when it ran; part of `latencyMs`.
    var correctionMs: Int? = nil

    /// Characters that were actually spoken: no spaces or punctuation.
    var spokenCharacters: Int {
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return text.unicodeScalars.filter { !skip.contains($0) }.count
    }
}

enum AppFiles {
    /// ~/Library/Application Support/Kay on the Mac (Kay is not sandboxed); the app container's on iOS.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kay")
    }
}

enum HistoryStore {
    static let limit = 1000

    static var url: URL { AppFiles.directory.appendingPathComponent("history.json") }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(entries.prefix(limit))) else { return }
        try? FileManager.default.createDirectory(at: AppFiles.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
