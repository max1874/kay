import AppKit

/// 屏幕底部居中的状态浮层，不抢焦点、不接收点击。
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String) {
        hideWork?.cancel()
        label.stringValue = text
        layout()
        panel.orderFrontRegardless()
    }

    func flash(_ text: String, seconds: TimeInterval = 2) {
        show(text)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(max(label.fittingSize.width + 40, 140), visible.width * 0.6)
        let height: CGFloat = 40
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 60, width: width, height: height),
                       display: true)
        label.frame = NSRect(x: 20, y: (height - 20) / 2, width: width - 40, height: 20)
    }
}
