import Foundation

/// The audio of a dictation in progress, kept on disk until its outcome is in history.
///
/// A process that ends between pressing the key and recording the result takes what was said with it:
/// 1.4.4–1.5.2 crashed at exactly that point on every dictation (one of them 4 minutes long), and an install
/// that quit Kay mid-dictation lost another (2026-10-07). So the 16 kHz PCM that goes to the speech service is also
/// appended to `pending-<time>.pcm`; recording the result — text or error — or cancelling deletes it. A file
/// still there at launch is a dictation that never landed: Kay recognizes it again and records it in history,
/// without pasting, since the place it was meant for is long gone.
///
/// Once the outcome is in history, the audio of the last 20 dictations is kept as `recent/<entry id>.wav`
/// (16 kHz mono, on this Mac only): a misrecognition can then be played back and sent again — to the speech service
/// with hotwords, or to another engine with tools/ab.py — instead of guessed at. Deleting an entry or
/// clearing history deletes its audio.
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

    static let recentLimit = 20
    static var recentDirectory: URL { AppFiles.directory.appendingPathComponent("recent") }

    /// There is no outcome to keep (cancelled, nothing heard): the audio is no longer needed.
    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The outcome is in history as entry `id`: keep the audio under that id among the recent ones.
    func keep(as id: UUID) {
        close()
        Self.keep(url, as: id)
    }

    private func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    static func keep(_ pcm: URL, as id: UUID) {
        defer { try? FileManager.default.removeItem(at: pcm) }
        guard let samples = try? Data(contentsOf: pcm), !samples.isEmpty else { return }
        let dir = recentDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (wavHeader(bytes: samples.count) + samples).write(to: dir.appendingPathComponent("\(id.uuidString).wav"))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in newestFirst.dropFirst(recentLimit) { try? FileManager.default.removeItem(at: old) }
    }

    static func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: recentDirectory.appendingPathComponent("\(id.uuidString).wav"))
    }

    static func forgetAll() {
        try? FileManager.default.removeItem(at: recentDirectory)
    }

    /// 16 kHz, 16-bit, mono PCM: what AudioCapture produces and the speech service is sent.
    private static func wavHeader(bytes: Int) -> Data {
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var header = Data("RIFF".utf8)
        header.append(u32(36 + bytes))
        header.append(Data("WAVEfmt ".utf8))
        // PCM, 1 channel, 16000 samples/s, 32000 bytes/s, 2 bytes per frame, 16 bits per sample.
        for field in [u32(16), u16(1), u16(1), u32(16000), u32(32000), u16(2), u16(16)] { header.append(field) }
        header.append(Data("data".utf8))
        header.append(u32(bytes))
        return header
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
