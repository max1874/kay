import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct KayWidgets: WidgetBundle {
    var body: some Widget {
        DictationControl()
        DictationLiveActivity()
    }
}

/// The switch people put on the Action Button, in Control Center or on the Lock Screen: on while Kay
/// listens, off once it stopped.
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.controlKind, provider: ListeningProvider()) { listening in
            ControlWidgetToggle("Dictate", isOn: listening, action: SetDictationIntent()) { on in
                Label(on ? "Listening" : "Dictate", systemImage: on ? "waveform" : "mic")
            }
            .tint(.red)
        }
        .displayName("Dictate with Kay")
        .description("Press to start, press again to stop. The text is copied to the clipboard.")
    }
}

private struct ListeningProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool { SharedState.isRecording }
}
