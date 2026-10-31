#if DEBUG
import AppKit
import SwiftUI

/// The main window and nothing else, so its settings panes can be looked at before a release without a second
/// Kay fighting the installed one for the hold-to-talk key:
///
///     CONFIG=debug macOS/scripts/build-app.sh
///     KAY_PREVIEW_SETTINGS=1 build/Kay.app/Contents/MacOS/Kay
///
/// `AppModel.start()` and the updater never run, so no key monitor, recording, update check or history (the
/// Dictations pane is empty). Settings are the real ones (same defaults domain): look, don't change. It opens
/// on the pane stored under `Pane.storageKey`; KAY_PREVIEW_DARK=1 shows it dark. Quit with Ctrl-C.
///
/// It opens under every other window, just above the wallpaper, and never in front of what you are doing:
/// `screencapture -l <window id>` captures it there (apple-developer, knowledge/macos-distribution.md).
///
/// AppKit rather than a SwiftUI `App`: launched from a shell, that one put up no window at all.
@MainActor
enum SettingsPreview {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.environment["KAY_PREVIEW_DARK"] != nil { app.appearance = NSAppearance(named: .darkAqua) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView()))
        window.title = "Kay Preview"
        window.setContentSize(NSSize(width: 960, height: 680))
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.center()
        window.orderFront(nil)
        app.run()
        exit(0)
    }
}
#endif
