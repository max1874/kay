import AppIntents

/// Puts "Dictate with Kay" in Shortcuts, Spotlight, Siri and the Action Button's Shortcut list without
/// anyone having to build a shortcut first. The Control (KayWidgets) covers the Action Button's Controls list.
struct KayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform"
        )
    }
}
