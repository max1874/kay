#if DEBUG
import Foundation

if ProcessInfo.processInfo.environment["KAY_PREVIEW_SETTINGS"] != nil {
    MainActor.assumeIsolated { SettingsPreview.run() }
}
#endif
KayApp.main()
