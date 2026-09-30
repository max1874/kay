import AppKit

/// 监听「按住右 Option」。按住期间如果按了其他键，视为组合键（如 ⌥ 打特殊字符），触发 onInterrupt。
/// 全局监听键盘事件需要辅助功能权限；授权后需重新注册监听才生效。
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onInterrupt: (() -> Void)?

    private static let rightOptionKeyCode: UInt16 = 61
    private static let rightOptionDeviceMask: UInt = 0x40  // NX_DEVICERALTKEYMASK

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
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let down = event.modifierFlags.rawValue & Self.rightOptionDeviceMask != 0
        guard down != isDown else { return }
        isDown = down
        if down { onPress?() } else { onRelease?() }
    }

    private func handleKeyDown() {
        if isDown { onInterrupt?() }
    }
}
