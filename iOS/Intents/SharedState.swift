import Foundation

/// What the app and the widget extension both need to know: whether Kay is listening, so the control
/// can stay lit for as long as it does. The app writes it; the control's value provider reads it.
enum SharedState {
    static let appGroup = "group.com.max1874.kay"
    static let controlKind = "com.max1874.kay.dictate"

    private static let defaults = UserDefaults(suiteName: appGroup)
    private static let recordingKey = "recording"

    static var isRecording: Bool {
        get { defaults?.bool(forKey: recordingKey) ?? false }
        set { defaults?.set(newValue, forKey: recordingKey) }
    }
}
