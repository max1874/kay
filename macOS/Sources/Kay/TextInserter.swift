import AppKit

/// 通过剪贴板 + 模拟 ⌘V 把文字插入当前光标处，之后恢复原剪贴板内容。需要辅助功能权限。
///
/// Failure class, read before changing anything here: the clipboard Kay saves belongs to another app, and
/// reading it can wait on that app. An item can be a promise that is only resolved when someone reads it;
/// on 2026-10-08 Xcode's DeviceHub never resolved one, and reading it held Kay's main thread for 25.8 s
/// (1.5.13): the text landed that much later and the HUD sat on Recognizing. So the dictated text never
/// waits for the old clipboard longer than `snapshotBudget`; past that the old clipboard is given up.
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9
    /// How long the old clipboard may hold up the paste. A plain copy reads in a few milliseconds.
    private static let snapshotBudget: TimeInterval = 0.25

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let started = Date()
        let saved = snapshot(pasteboard, within: snapshotBudget)
        let waited = Int(Date().timeIntervalSince(started) * 1000)
        if saved == nil {
            log.notice("the clipboard didn't read within \(waited, privacy: .public) ms; pasting without restoring it")
        }
        // Someone wrote to it while it was being read: what was read is no longer what they have there.
        let restore = pasteboard.changeCount == before ? saved : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        log.notice("pasted after \(waited, privacy: .public) ms on the clipboard")

        guard let restore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 期间用户又复制了别的内容就不覆盖
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !restore.isEmpty { pasteboard.writeObjects(restore) }
        }
    }

    /// A copy of every item on the clipboard, or nil when it took longer than `budget`. Past the budget the
    /// read goes on in the background until the owning app answers, and its result is dropped. Not a serial
    /// queue: the next dictation's read must not wait behind one that is stuck.
    private static func snapshot(_ pasteboard: NSPasteboard, within budget: TimeInterval) -> [NSPasteboardItem]? {
        final class Box { var items: [NSPasteboardItem] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.items = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            done.signal()
        }
        return done.wait(timeout: .now() + budget) == .success ? box.items : nil
    }
}
