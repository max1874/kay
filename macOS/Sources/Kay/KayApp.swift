import AppKit
import Combine
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
        // kay://main opens it. SwiftUI didn't bring a suppressed window back on its own when Kay was opened
        // again (1.4.2–1.4.3), and nothing outside a view can call openWindow.
        .handlesExternalEvents(matching: [KayApp.mainWindow])
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

    static func showMainWindow() {
        NSApp.activate()
        // A minimized window still exists, and SwiftUI won't open it again: 1.5.10 got its window minimized,
        // then neither the Dock icon nor Spotlight could bring it back. Bring it back here.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == mainWindow && $0.isMiniaturized }) {
            log.notice("restoring the minimized main window")
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSWorkspace.shared.open(URL(string: "kay://\(mainWindow)")!)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitWhenIdle: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !AppModel.showsDockIcon { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        Updater.shared.start()
        // After the close, when the window no longer counts as visible.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { _ in
            DispatchQueue.main.async { AppModel.hideDockIconIfWindowless() }
        }
        // Max pressed ⌘, and the main window went to the Dock (2026-10-08); nothing recorded why. With the
        // event that was being handled, the next one says.
        NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil,
                                               queue: .main) { note in
            let window = note.object as? NSWindow
            let event = NSApp.currentEvent.map { "\($0.type.rawValue) \($0.charactersIgnoringModifiers ?? "")" } ?? "none"
            log.notice("window minimized: \(window?.identifier?.rawValue ?? "?", privacy: .public), event \(event, privacy: .public)")
        }
    }

    /// Clicking the Dock icon, or opening Kay again from Spotlight or Finder, with no window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { KayApp.showMainWindow() }
        return false
    }

    /// Dictation lives on the hotkey, not the window: closing it must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A quit while you are dictating (an install replacing Kay, logout, the menu) waits for the text to
    /// land: quitting there loses what was said. A dictation that never ends doesn't hold the quit past 60 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.state != .idle else { return .terminateNow }
        guard quitWhenIdle == nil else { return .terminateLater }
        log.notice("quit requested while dictating; quitting once it lands")
        let quit = { [weak self] in
            guard let self, self.quitWhenIdle != nil else { return }
            self.quitWhenIdle = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        quitWhenIdle = AppModel.shared.$state.first { $0 == .idle }.sink { _ in DispatchQueue.main.async(execute: quit) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: quit)
        return .terminateLater
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
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Divider()
        Button("Quit Kay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
