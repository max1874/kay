import AppKit
import SwiftUI

/// The glass capsule above the Dock while you dictate. It never takes focus or clicks: the text is
/// about to land in whatever app you are typing in, and that app has to stay frontmost.
final class HUD {
    private let content = HUDState()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func listen(since start: Date) {
        content.levels = Array(repeating: 0, count: HUDState.barCount)
        present(.listening(since: start))
    }

    func level(_ value: Float) {
        guard case .listening = content.mode else { return }
        content.levels.append(value)
        content.levels.removeFirst()
    }

    func recognize() {
        present(.recognizing)
    }

    func flash(_ text: String, symbol: String, seconds: TimeInterval = 2) {
        present(.message(text, symbol: symbol))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func present(_ mode: HUDState.Mode) {
        hideWork?.cancel()
        let panel = panel ?? make()
        self.panel = panel
        content.mode = mode
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            panel.setContentSize(host.fittingSize)
        }
        place(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: HUDView(state: content))
        // The window shadow follows the layer; unclipped, it would box the capsule in grey.
        host.wantsLayer = true
        host.layer?.cornerRadius = HUDView.height / 2
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        return panel
    }

    /// Above the Dock on the screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 56))
    }
}

final class HUDState: ObservableObject {
    enum Mode: Equatable {
        case listening(since: Date)
        case recognizing
        case message(String, symbol: String)
    }

    static let barCount = 14

    @Published var mode = Mode.recognizing
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
}

private struct HUDView: View {
    @ObservedObject var state: HUDState

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            switch state.mode {
            case .listening(let since):
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                LevelBars(levels: state.levels, tint: .primary, barWidth: 3, spacing: 2.5)
                    .frame(width: CGFloat(HUDState.barCount) * 5.5, height: 18)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(verbatim: Format.clock(context.date.timeIntervalSince(since)))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .recognizing:
                ProgressView().controlSize(.small)
                Text("Recognizing…").font(.system(size: 13, weight: .medium))
            case .message(let text, let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: Self.height)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Bars for recent input levels, newest on the right. Shared by the HUD and the window's live view.
struct LevelBars: View {
    let levels: [Float]
    var tint: Color = .red
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(tint)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}
