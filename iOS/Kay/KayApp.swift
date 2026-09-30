import AVFoundation
import SwiftUI

@main
struct KayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Asked here, in the foreground: the control may later start the microphone with
                    // no Kay on screen, and a permission prompt cannot appear then.
                    if AVAudioApplication.shared.recordPermission == .undetermined {
                        _ = await AVAudioApplication.requestRecordPermission()
                    }
                    let speech = SpeechService.shared
                    if speech.hasKey, speech.status == .saved {
                        await speech.test(newKey: nil)
                    }
                }
        }
    }
}
