import AppKit

/// The key you hold to dictate.
enum Trigger: String, CaseIterable, Identifiable {
    /// fn / 🌐, bottom left on Mac keyboards. The default, as in other dictation apps.
    case fn
    case rightOption

    var id: String { rawValue }

    static let defaultsKey = "trigger"

    /// The name used in sentences such as "Hold fn to Dictate".
    var name: String {
        switch self {
        case .fn: "fn"
        case .rightOption: String(localized: "Right Option")
        }
    }

    fileprivate var keyCode: UInt16 {
        switch self {
        case .fn: 63  // kVK_Function
        case .rightOption: 61  // kVK_RightOption
        }
    }

    fileprivate func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn: flags.contains(.function)
        case .rightOption: flags.rawValue & 0x40 != 0  // NX_DEVICERALTKEYMASK: the right one only
        }
    }
}

/// 监听「按住触发键」。按住期间如果按了其他键，视为组合键（如 fn+↑、⌥ 打特殊字符），触发 onInterrupt。
/// 全局监听键盘事件需要辅助功能权限；授权后需重新注册监听才生效。
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onInterrupt: (() -> Void)?

    var trigger = Trigger.fn {
        didSet {
            if isDown { onInterrupt?() }
            isDown = false
        }
    }

    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] in self?.handleFlags($0) }
        let keyDown: (NSEvent) -> Void = { [weak self] _ in self?.handleKeyDown() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyDown($0); return $0 },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == trigger.keyCode else { return }
        let down = trigger.isDown(event.modifierFlags)
        guard down != isDown else { return }
        isDown = down
        if down { onPress?() } else { onRelease?() }
    }

    private func handleKeyDown() {
        if isDown { onInterrupt?() }
    }
}
