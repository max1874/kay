import AppKit
import SwiftUI

struct KayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Only this, never AppModel: the scene body re-runs whenever what it reads changes, and binding a
    // scene to the model made each menu-bar refresh publish a change that refreshed it again.
    @AppStorage(AppModel.menuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Kay", id: KayApp.mainWindow) {
            ContentView()
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)
        // Read once: this scene must not depend on changing state (see showMenuBarIcon).
        .defaultLaunchBehavior(AppModel.showsDockIcon ? .automatic : .suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }

        // MenuBarExtra writes the binding back as it updates; only a real change may reach storage.
        MenuBarExtra(isInserted: Binding(get: { showMenuBarIcon },
                                         set: { if $0 != showMenuBarIcon { showMenuBarIcon = $0 } })) {
            MenuBarMenu()
        } label: {
            MenuBarIcon()
        }
    }

    static let mainWindow = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !AppModel.showsDockIcon { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Dictation lives on the hotkey, not the window: closing it must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarIcon: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Image(systemName: model.state == .idle ? "waveform" : "waveform.badge.mic")
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
