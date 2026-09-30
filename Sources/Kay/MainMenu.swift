import AppKit

/// The standard menus. On macOS the key equivalents (⌘V in the API key field, ⌘W, ⌘Q) come
/// from menu items and nowhere else, so an app without these has none of them. Adapted from Lumo.
enum MainMenu {
    static func install() {
        let menu = NSMenu()
        menu.addItem(app)
        menu.addItem(edit)
        menu.addItem(window)
        NSApp.mainMenu = menu
    }

    private static var app: NSMenuItem {
        submenu("Kay") { menu in
            menu.addItem(
                withTitle: String(localized: "About Kay"),
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            // No target, so it travels the responder chain to the app delegate.
            menu.addItem(
                withTitle: String(localized: "Settings…"),
                action: #selector(AppDelegate.openSettingsFromMenu(_:)), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(
                withTitle: String(localized: "Hide Kay"),
                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = menu.addItem(
                withTitle: String(localized: "Hide Others"),
                action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(
                withTitle: String(localized: "Show All"),
                action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(
                withTitle: String(localized: "Quit Kay"),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    private static var edit: NSMenuItem {
        submenu(String(localized: "Edit")) { menu in
            menu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
            let redo = menu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }
    }

    private static var window: NSMenuItem {
        let item = submenu(String(localized: "Window")) { menu in
            menu.addItem(
                withTitle: String(localized: "Minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(
                withTitle: String(localized: "Close"),
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            menu.addItem(.separator())
            menu.addItem(
                withTitle: String(localized: "Kay Window"),
                action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        }
        NSApp.windowsMenu = item.submenu  // AppKit keeps the window list in it
        return item
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }
}
