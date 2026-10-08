#if DEBUG
import AppKit
import SwiftUI

/// The Settings view in a window of its own and nothing else, so it can be looked at before a release
/// without a second Kay fighting the installed one for the hold-to-talk key:
///
///     CONFIG=debug macOS/scripts/build-app.sh
///     KAY_PREVIEW_SETTINGS=1 build/Kay.app/Contents/MacOS/Kay
///
/// `AppModel.start()` and the updater never run, so no key monitor, recording or update check. Settings
/// are the real ones (same defaults domain): look, don't change. The panes show as a tab bar rather than
/// the Settings window's toolbar; what's inside them is the same. Quit with Ctrl-C.
///
/// AppKit rather than a SwiftUI `App`: launched from a shell, that one put up no window at all.
@MainActor
enum SettingsPreview {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "Settings Preview"
        window.center()
        window.orderFrontRegardless()
        app.run()
        exit(0)
    }
}
#endif
