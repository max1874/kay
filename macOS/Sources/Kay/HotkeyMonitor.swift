import AppKit

/// A key you hold to dictate, or several held together: modifier keys only, told apart by side, since modifiers
/// alone type nothing. Any keyboard's keys count, so an HHKB's Alt works as Right Option; a key the keyboard
/// keeps to itself, such as the HHKB's own Fn, never reaches macOS.
struct Trigger: OptionSet, Hashable, Identifiable {
    let rawValue: UInt
    var id: UInt { rawValue }

    // The device-dependent bits of NSEvent.ModifierFlags (NX_DEVICE…KEYMASK in IOLLEvent.h); fn has no side.
    static let fn = Trigger(rawValue: NSEvent.ModifierFlags.function.rawValue)
    static let leftControl = Trigger(rawValue: 0x0001)
    static let rightControl = Trigger(rawValue: 0x2000)
    static let leftOption = Trigger(rawValue: 0x0020)
    static let rightOption = Trigger(rawValue: 0x0040)
    static let leftShift = Trigger(rawValue: 0x0002)
    static let rightShift = Trigger(rawValue: 0x0004)
    static let leftCommand = Trigger(rawValue: 0x0008)
    static let rightCommand = Trigger(rawValue: 0x0010)

    /// fn first, as on the keyboard, then the HIG's order: Control, Option, Shift, Command.
    private static let keys: [(key: Trigger, symbol: String, name: String)] = [
        (.fn, "fn", "fn"),
        (.leftControl, "⌃", String(localized: "Left Control")),
        (.rightControl, "⌃", String(localized: "Right Control")),
        (.leftOption, "⌥", String(localized: "Left Option")),
        (.rightOption, "⌥", String(localized: "Right Option")),
        (.leftShift, "⇧", String(localized: "Left Shift")),
        (.rightShift, "⇧", String(localized: "Right Shift")),
        (.leftCommand, "⌘", String(localized: "Left Command")),
        (.rightCommand, "⌘", String(localized: "Right Command")),
    ]
    private static let all = Trigger(keys.map(\.key))

    init(rawValue: UInt) { self.rawValue = rawValue }
    /// The keys down after a flagsChanged event, given those down before it. Caps Lock locks rather than holds, so
    /// it is left out. Arrow and function keys carry .function while held, so only fn's own event changes fn.
    init(after event: NSEvent, from before: Trigger) {
        self.init(rawValue: event.modifierFlags.rawValue & Self.all.rawValue)
        if event.keyCode != 63 { self = subtracting(.fn).union(before.intersection(.fn)) }  // kVK_Function
    }

    private var parts: [(key: Trigger, symbol: String, name: String)] { Self.keys.filter { contains($0.key) } }

    /// The name used in sentences such as "Hold fn to Dictate".
    var name: String { parts.map(\.name).joined(separator: " + ") }
    /// As printed on the keycaps: "⌃⌥", or "⌥" for either Option.
    var symbols: String { parts.map(\.symbol).joined() }

    private static let defaultsKey = "triggers"

    /// Until 1.17 there was one trigger, stored under "trigger" as "fn" or "rightOption".
    static func load() -> [Trigger] {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: defaultsKey) as? [UInt], !stored.isEmpty {
            return stored.map(Trigger.init(rawValue:))
        }
        return [defaults.string(forKey: "trigger") == "rightOption" ? .rightOption : .fn]
    }

    static func save(_ triggers: [Trigger]) {
        UserDefaults.standard.set(triggers.map(\.rawValue), forKey: defaultsKey)
    }
}

/// 监听「按住触发键」。按住期间如果按了其他键，视为组合键（如 fn+↑、⌥ 打特殊字符），触发 onInterrupt。
/// 全局监听键盘事件需要辅助功能权限；授权后需重新注册监听才生效。
///
/// Idle, Kay listens to modifier changes only. The key-down monitor, which would otherwise wake it for every
/// keystroke in every app, exists only while a trigger is held.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onInterrupt: (() -> Void)?

    var triggers: [Trigger] = [.fn] {
        didSet { interrupt() }
    }
    /// While Settings records a trigger, keys pressed in Kay's own windows don't start a dictation; other apps
    /// still do.
    var recording = false

    private var flagMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    /// Every modifier down as of the last change.
    private var down = Trigger()
    /// The trigger being held, while one is.
    private var held: Trigger? {
        didSet { if (held == nil) != (oldValue == nil) { held == nil ? unwatchKeys() : watchKeys() } }
    }

    func start() {
        stop()
        flagMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in
                self?.handleFlags($0, canStart: true)
            },
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in
                self?.handleFlags($0, canStart: self?.recording == false)
                return $0
            },
        ].compactMap { $0 }
    }

    /// With the monitors gone a release would never arrive, so a dictation in progress is cancelled.
    func stop() {
        flagMonitors.forEach(NSEvent.removeMonitor)
        flagMonitors = []
        interrupt()
        down = []
    }

    private func watchKeys() {
        let keyDown: (NSEvent) -> Void = { [weak self] _ in self?.interrupt() }
        keyMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyDown($0); return $0 },
        ].compactMap { $0 }
    }

    private func unwatchKeys() {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
    }

    /// A trigger starts only as its last key goes down, so letting go of ⌘ in ⌘⇧ never starts a ⇧ trigger. Once
    /// held, letting go of one of its keys ends the dictation, and another modifier joining cancels it, as a key does.
    private func handleFlags(_ event: NSEvent, canStart: Bool) {
        let now = Trigger(after: event, from: down)
        defer { down = now }
        if let held {
            guard now != held else { return }
            self.held = nil
            now.isSubset(of: held) ? onRelease?() : onInterrupt?()
        } else if canStart, now.isStrictSuperset(of: down), triggers.contains(now) {
            held = now
            onPress?()
        }
    }

    private func interrupt() {
        guard held != nil else { return }
        held = nil
        onInterrupt?()
    }
}
