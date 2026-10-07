import Foundation

/// The audio of a dictation in progress, kept on disk until its outcome is in history.
///
/// A process that ends between pressing the key and recording the result takes what was said with it:
/// 1.4.4–1.5.2 crashed at exactly that point on every dictation (one of them 4 minutes long), and an install
/// that quit Kay mid-dictation lost another (2026-10-07). So the 16 kHz PCM that goes to Doubao is also
/// appended to `pending-<time>.pcm`; recording the result — text or error — or cancelling deletes it. A file
/// still there at launch is a dictation that never landed: Kay recognizes it again and records it in history,
/// without pasting, since the place it was meant for is long gone.
final class PendingDictation {
    private static let prefix = "pending-"
    /// Leftovers that keep failing (no key, no network) are retried at each launch, but not forever.
    private static let keepFor: TimeInterval = 7 * 24 * 3600

    let url: URL
    private let queue = DispatchQueue(label: "kay.pending")
    private var handle: FileHandle?

    /// nil if the file can't be made; dictation goes on without it.
    init?() {
        let dir = AppFiles.directory
        url = dir.appendingPathComponent("\(Self.prefix)\(Int(Date().timeIntervalSince1970 * 1000)).pcm")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            log.error("pending audio not kept: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Called from the audio queue as packets go out.
    func append(_ pcm: Data) {
        queue.async { try? self.handle?.write(contentsOf: pcm) }
    }

    /// The outcome is in history (or there is none to keep): the audio is no longer needed.
    func discard() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Dictations a previous run didn't finish, oldest first, with when they were started.
    static func leftovers() -> [(url: URL, started: Date)] {
        let dir = AppFiles.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (url: URL, started: Date)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".pcm"),
                  let ms = Double(name.dropFirst(prefix.count).dropLast(4)) else { return nil }
            let url = dir.appendingPathComponent(name)
            let started = Date(timeIntervalSince1970: ms / 1000)
            if Date().timeIntervalSince(started) > keepFor {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url: url, started: started)
        }
        .sorted { $0.started < $1.started }
    }
}
