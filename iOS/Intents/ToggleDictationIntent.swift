import AppIntents
import Foundation

/// The Action Button / Control Center / Lock Screen control: press to start listening, press again to
/// stop; the text lands on the clipboard. An `AudioRecordingIntent` may start the microphone without
/// opening the app, provided a Live Activity runs for as long as it records.
///
/// The widget extension compiles this too, so the control can name it, but the system performs it in
/// the app's process; the extension's copy never runs, hence `KAY_WIDGET`.
struct ToggleDictationIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Dictate with Kay"
    static let description = IntentDescription("Start or stop a dictation. When it stops, the text is copied to the clipboard.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if !KAY_WIDGET
        try await DictationController.shared.toggle()
        #endif
        return .result()
    }
}
