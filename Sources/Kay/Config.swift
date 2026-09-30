import Foundation

enum AppFiles {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kay")
    }
}

/// 1.0.0 kept the API key in a JSON file; from 1.1.0 it lives in the Keychain.
/// Only read once, to move the key over, then deleted.
enum LegacyConfig {
    private struct Config: Codable {
        var volcApiKey: String
    }

    private static var url: URL { AppFiles.directory.appendingPathComponent("config.json") }

    static func takeApiKey() -> String? {
        guard let data = try? Data(contentsOf: url),
              let key = try? JSONDecoder().decode(Config.self, from: data).volcApiKey,
              !key.isEmpty
        else { return nil }
        return key
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
