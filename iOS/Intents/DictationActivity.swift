import ActivityKit
import Foundation

/// What the Dynamic Island and the Lock Screen show while Kay dictates. Compiled into the app, which
/// starts and updates the activity, and the widget extension, which draws it.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// `tapToCopy`: recognized, but iOS kept the clipboard from Kay in the background; tapping the
            /// activity opens Kay, which copies it then.
            case listening, recognizing, copied, tapToCopy, failed
        }

        var phase: Phase
        var startedAt: Date
        /// The recognized text once copied, or the reason it failed.
        var message: String?
    }
}
