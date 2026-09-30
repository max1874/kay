import AppKit
import Combine
import Sparkle

/// Keeping the installed copy current, quietly.
///
/// Kay is a notarized download, so nothing else will replace it. Sparkle checks the appcast once a day
/// (`SUFeedURL`, `SUScheduledCheckInterval` in Info.plist) and downloads an update by itself
/// (`SUAutomaticallyUpdate`). What it would normally do next — install when the app quits — never comes
/// for an app that runs until logout, so Kay installs as soon as it is not dictating: Sparkle swaps the app
/// and relaunches it, windowless again when the Dock icon is off. An update is refused unless it is signed
/// with the key whose public half is `SUPublicEDKey`.
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var pendingInstall: (() -> Void)?
    private var waitForIdle: AnyCancellable?

    func start() {
        controller.startUpdater()
    }

    /// The menu item: the one time Sparkle shows its own window.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        log.notice("update \(item.displayVersionString, privacy: .public) downloaded, installing when idle")
        pendingInstall = immediateInstallationBlock
        installWhenIdle()
        return true
    }

    private func installWhenIdle() {
        guard let install = pendingInstall else { return }
        guard AppModel.shared.state == .idle else {
            // Never in the middle of a dictation: the text would be lost with the process.
            waitForIdle = AppModel.shared.$state.first { $0 == .idle }.sink { [weak self] _ in
                DispatchQueue.main.async { self?.installWhenIdle() }
            }
            return
        }
        pendingInstall = nil
        waitForIdle = nil
        install()
    }
}
