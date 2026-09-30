import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var audioSeconds: Double
    var latencyMs: Int?
    /// Set when recognition failed; `text` is empty then.
    var error: String?

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
