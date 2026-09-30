import AVFoundation
import SwiftUI

@main
struct KayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) {
                    if scenePhase == .active { DictationController.shared.becameActive() }
                }
                .task {
                    #if DEBUG
                    if let name = UserDefaults.standard.string(forKey: "KayDemo") {
                        await DictationController.shared.demo(name)
                    }
                    #endif
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
