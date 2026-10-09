import Foundation
import os

let log = KayLog()

/// Kay's log: the unified log, as before, plus `~/Library/Logs/Kay/kay.log`.
///
/// The unified log on Max's Mac keeps less than a day, and what decides a dictation problem is often Core Audio's
/// own lines next to Kay's (2026-10-09: the main thread hung inside AVAudioEngine; by the next morning the lines
/// that showed why would have been gone). The file keeps Kay's side for weeks; `HangWatchdog` adds the system's
/// side when the main thread stops answering. Lines carry counts, devices and timings, never dictated text.
struct KayLog {
    private let logger = Logger(subsystem: "com.max1874.kay", category: "app")

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LogFile.shared.append(message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.shared.append("error: " + message)
    }
}

/// Appends lines on a queue of its own, so the file keeps getting written while the main thread is stuck.
/// Four files of 2 MB (a dictation writes under 1 kB): kay.log, then kay.1.log … kay.3.log, oldest last.
final class LogFile {
    static let shared = LogFile()
    static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Kay", isDirectory: true)

    private static let maxBytes = 2_000_000
    private static let keep = 3

    private let url = LogFile.directory.appendingPathComponent("kay.log")
    private let queue = DispatchQueue(label: "kay.logfile", qos: .utility)
    private var handle: FileHandle?
    private var written = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func append(_ message: String) {
        let date = Date()
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            let line = "\(self.stamp.string(from: date)) [\(pid)] \(message)\n"
            guard let handle = self.open() else { return }
            let data = Data(line.utf8)
            // FileHandle.write goes straight to write(2): a line is on disk once this returns, crash or not.
            try? handle.write(contentsOf: data)
            self.written += data.count
            if self.written > Self.maxBytes { self.rotate() }
        }
    }

    /// Waits until every line appended so far is written.
    func flush() {
        queue.sync {}
    }

    private func open() -> FileHandle? {
        if let handle { return handle }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // O_APPEND: during an update the Kay that is quitting and the one starting both write here.
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        written = Int((try? handle.seekToEnd()) ?? 0)
        self.handle = handle
        return handle
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        func numbered(_ n: Int) -> URL { Self.directory.appendingPathComponent("kay.\(n).log") }
        try? fm.removeItem(at: numbered(Self.keep))
        for n in stride(from: Self.keep - 1, through: 1, by: -1) {
            try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
        }
        try? fm.moveItem(at: url, to: numbered(1))
    }
}
