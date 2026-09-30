import AppIntents
import Foundation

/// The stop button on the Live Activity (Lock Screen, expanded Dynamic Island), like Voice Memos'.
/// Stop only, so a late second tap can't start a new dictation. Same process rules as `ToggleDictationIntent`.
struct StopDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !KAY_WIDGET
        await DictationController.shared.stop()
        #endif
        return .result()
    }
}
