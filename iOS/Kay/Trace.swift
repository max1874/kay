import Foundation

// TEMPORARY: diagnosing the control path on device (pulled with `devicectl device copy from`). Remove once
// the Action Button / Control Center path is verified.
enum Trace {
    static func log(_ message: String) {
        let url = AppFiles.directory.appendingPathComponent("trace.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(ProcessInfo.processInfo.processName)] \(message)\n"
        try? FileManager.default.createDirectory(at: AppFiles.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
