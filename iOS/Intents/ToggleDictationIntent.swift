import AppIntents
import Foundation

/// The Action Button / Control Center / Lock Screen control: press to start listening, press again to
/// stop; the text lands on the clipboard. An `AudioRecordingIntent` may start the microphone without
/// opening the app, provided a Live Activity runs for as long as it records.
///
/// The widget extension compiles this too, so the control can name it, but only the app can record:
/// `allowedExecutionTargets` pins it to the app's process, so the extension's copy never runs, hence
/// `KAY_WIDGET`. Without it iOS 27 performed the control's press in the extension, where it did nothing
/// (2026-09-30, iPhone 17 Pro).
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Dictate with Kay"
    static let description = IntentDescription("Start or stop a dictation. When it stops, the text is copied to the clipboard.")
    static let openAppWhenRun = false

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    /// Returns the text on the press that stops, empty on the one that starts. iOS keeps the clipboard from
    /// Kay in the background (changeCount stays 0, 2026-09-30), but not from Shortcuts: a shortcut of this
    /// action followed by Copy to Clipboard gets the text there.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        #if !KAY_WIDGET
        let text = try await DictationController.shared.toggle()
        return .result(value: text ?? "")
        #else
        return .result(value: "")
        #endif
    }
}
