import ActivityKit
import Foundation

/// What the Dynamic Island and the Lock Screen show while Kay dictates. Compiled into the app, which
/// starts and updates the activity, and the widget extension, which draws it.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening, recognizing, copied, failed
        }

        var phase: Phase
        var startedAt: Date
        /// The recognized text once copied, or the reason it failed.
        var message: String?
    }
}
