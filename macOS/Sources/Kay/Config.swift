import Foundation

/// A private setup file explicitly prepared for this installation, consumed once by Kay.
/// The app itself saves the key, preserving Keychain access under its signing identity.
/// Old Volcengine configuration and its Keychain item remain untouched for rollback.
struct QwenSetup: Decodable {
    let apiKey: String
    let workspaceURL: String

    private static var url: URL { AppFiles.directory.appendingPathComponent("qwen-setup.json") }

    static func load() -> QwenSetup? {
        guard let data = try? Data(contentsOf: url),
              let setup = try? JSONDecoder().decode(Self.self, from: data),
              !setup.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return setup
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}
