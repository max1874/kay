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
            // Characters only for a key event: asked of any other event, AppKit throws (1.5.11, on every
            // minimize from the Dock's own transaction).
            let event = NSApp.currentEvent.map { e -> String in
                let keys = e.type == .keyDown || e.type == .keyUp ? " \(e.modifierFlags.rawValue) \(e.charactersIgnoringModifiers ?? "")" : ""
                // Where a click landed, in which window, and how many: the yellow button, a double click on
                // a title bar, or something else. Click count only for a mouse event, for the same reason.
                let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
                let click = mouse.contains(e.type)
                    ? " in \(e.window?.identifier?.rawValue ?? e.window?.title ?? "no window") at \(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y)) x\(e.clickCount)"
                    : ""
                return "type \(e.type.rawValue)\(keys)\(click)"
            } ?? "none"
            log.notice("window minimized: \(window?.identifier?.rawValue ?? "?"), event \(event)")
        }
    }

    /// Clicking the Dock icon, or opening Kay again from Spotlight or Finder, with no window up.
    /// `hasVisibleWindows` counts a minimized window as visible, so 1.5.11 never got as far as restoring
    /// one: what counts here is a window actually on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let onScreen = sender.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.titled) }
        log.notice("reopen: \(hasVisibleWindows ? "visible" : "no visible") windows by AppKit's count, \(onScreen ? "one" : "none") on screen")
        if !onScreen { KayApp.showMainWindow() }
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
