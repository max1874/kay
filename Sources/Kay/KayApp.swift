import AppKit
import SwiftUI

struct KayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Kay", id: KayApp.mainWindow) {
            ContentView()
        }
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $model.showMenuBarIcon) {
            MenuBarMenu()
        } label: {
            Image(systemName: model.state == .idle ? "waveform" : "waveform.badge.mic")
        }
    }

    static let mainWindow = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Dictation lives on the hotkey, not the window: closing it must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Kay") {
            NSApp.activate()
            openWindow(id: KayApp.mainWindow)
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Kay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
