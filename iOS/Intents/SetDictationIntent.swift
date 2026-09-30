import AppIntents
import Foundation

/// The control's on/off: on starts listening, off stops and copies. A toggle rather than a button so the
/// control stays lit while Kay listens. Same process rules as `ToggleDictationIntent`.
struct SetDictationIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Dictate with Kay"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Listening")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !KAY_WIDGET
        // A press always means "the other state": the lit/unlit look can lag behind Kay (a stale value, a
        // process that died mid-dictation), and acting on `value` would then do nothing.
        try await DictationController.shared.toggle()
        #endif
        return .result()
    }
}
