import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var observers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        model.start()
        model.$showMenuBarIcon
            .sink { [weak self] in self?.setStatusItem(visible: $0) }
            .store(in: &observers)
        model.$state
            .sink { [weak self] in self?.updateStatusIcon($0) }
            .store(in: &observers)
        showMainWindow(nil)
    }

    /// Dictation lives on the hotkey, not the window: closing it must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return false
    }

    // MARK: - Window

    @objc func showMainWindow(_ sender: Any?) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: MainView())
            window.isReleasedWhenClosed = false  // reopened, not rebuilt
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.setFrameAutosaveName("KayMainWindow")
            if !window.setFrameUsingName("KayMainWindow") { window.center() }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettingsFromMenu(_ sender: Any?) {
        model.pane = .general
        showMainWindow(nil)
    }

    // MARK: - Menu bar icon

    private func setStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Open Kay"), action: #selector(showMainWindow(_:)), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettingsFromMenu(_:)), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Quit Kay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
            updateStatusIcon(model.state)
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateStatusIcon(_ state: AppModel.State) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "waveform"
        case .recording: symbol = "mic.fill"
        case .processing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kay")
        if state == .recording {
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            image?.isTemplate = true
            button.image = image
        }
    }
}
