import Foundation

/// Notices the main thread not answering during a dictation and keeps the evidence.
///
/// 2026-10-09: the main thread hung for good inside AVAudioEngine when a dictation began. A hang leaves no crash
/// report, the HUD and the Dock icon just stop responding, and the unified log here keeps less than a day. So while
/// armed, a thread of its own asks the main thread for a beat every half second; after `threshold` without one it
/// writes `~/Library/Logs/Kay/hangs/<time>/` with a `sample` of Kay (every thread's stack) and the last minutes of
/// Kay's unified log, which includes the Core Audio client's lines in Kay (not coreaudiod's). One snapshot per stall.
///
/// Armed only from a key press until the dictation is over: idle, Kay should not wake up at all.
final class HangWatchdog {
    static let shared = HangWatchdog()

    private static let threshold: TimeInterval = 3
    private static let keepSnapshots = 20

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var armed = false
    private var asked: Date?          // when the beat still outstanding was asked for
    private var stalled = false       // this stall already has its snapshot
    private var thread: Thread?

    func arm() {
        lock.lock()
        let wasArmed = armed
        armed = true
        if thread == nil {
            let thread = Thread { [unowned self] in self.run() }
            thread.name = "kay.watchdog"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
        }
        lock.unlock()
        if !wasArmed { wake.signal() }
    }

    func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    private func run() {
        while true {
            lock.lock()
            let isArmed = armed
            lock.unlock()
            if !isArmed {
                wake.wait()
                continue
            }
            Thread.sleep(forTimeInterval: 0.5)
            check()
        }
    }

    private func check() {
        let now = Date()
        lock.lock()
        guard armed else { return lock.unlock() }
        guard let asked else {
            self.asked = now
            lock.unlock()
            DispatchQueue.main.async { self.beat() }
            return
        }
        let waited = now.timeIntervalSince(asked)
        let snapshot = waited >= Self.threshold && !stalled
        if snapshot { stalled = true }
        lock.unlock()
        if snapshot {
            log.error("main thread hasn't answered for \(String(format: "%.1f", waited)) s; saving a snapshot")
            saveSnapshot()
        }
    }

    private func beat() {
        lock.lock()
        let since = asked.map { Date().timeIntervalSince($0) }
        let wasStalled = stalled
        asked = nil
        stalled = false
        lock.unlock()
        if wasStalled, let since {
            log.notice("main thread answered again after \(String(format: "%.1f", since)) s")
        }
    }

    private func saveSnapshot() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let hangs = LogFile.directory.appendingPathComponent("hangs", isDirectory: true)
        let dir = hangs.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("hang snapshot not saved: \(error.localizedDescription)")
            return
        }
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        // Every 10 ms rather than sample's 1 ms: it pauses Kay's threads to read them, a recording's among them.
        run("/usr/bin/sample", [pid, "3", "10", "-file", dir.appendingPathComponent("sample.txt").path], output: nil)
        run("/usr/bin/log", ["show", "--last", "5m", "--style", "compact", "--predicate", "processID == \(pid)"],
            output: dir.appendingPathComponent("unified.log"))
        LogFile.shared.flush()
        try? fm.copyItem(at: LogFile.directory.appendingPathComponent("kay.log"),
                         to: dir.appendingPathComponent("kay.log"))
        log.notice("hang snapshot saved in \(dir.path)")

        let all = (try? fm.contentsOfDirectory(at: hangs, includingPropertiesForKeys: nil)) ?? []
        for old in all.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(Self.keepSnapshots) {
            try? fm.removeItem(at: old)
        }
    }

    private func run(_ tool: String, _ arguments: [String], output: URL?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        var handle: FileHandle?
        if let output, FileManager.default.createFile(atPath: output.path, contents: nil) {
            handle = try? FileHandle(forWritingTo: output)
        }
        process.standardOutput = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("\(tool) didn't run: \(error.localizedDescription)")
        }
    }
}
