import AppKit
import SwiftUI

/// The dark pill above the Dock while you dictate. It never takes focus or clicks: the text is
/// about to land in whatever app you are typing in, and that app has to stay frontmost.
///
/// Failure class, read before changing anything here: resizing this panel while its SwiftUI content is
/// changing makes AppKit's Update Constraints pass loop — the hosting view's frame moves, SwiftUI asks for
/// one more update, AppKit runs one more pass — until AppKit throws and the process dies, on the path every
/// dictation takes, so the text is lost with it. It happened in 1.3.1 (the panel sized itself to the level
/// bars) and in 1.4.4–1.5.2 (Kay resized the panel when Recognizing took over; every dictation crashed for
/// 27 hours, and 1.5.2 only removed an animation that fed the loop). So the panel never changes size: it is
/// a fixed transparent canvas, the capsule sits at its bottom center, and only the capsule changes. Only a
/// real dictation proves a change here: an offscreen render has no display cycle and cannot show this.
final class HUD {
    /// Room for the widest capsule (a two-line message) and its shadow.
    static let canvas = CGSize(width: 560, height: 120)
    static let shadowRoom: CGFloat = 12

    private let content = HUDState()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func listen() {
        content.levels = Array(repeating: 0, count: HUDState.levelCount)
        present(.listening)
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
        } completionHandler: { [content] in
            // A dictation that began during the fade has already brought the panel back.
            guard panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            // An ordered-out panel keeps its views running: left on .recognizing, the spinner went on
            // animating after every dictation (≈15 % CPU, 1.4.2).
            content.mode = .idle
        }
    }

    private func present(_ mode: HUDState.Mode) {
        hideWork?.cancel()
        let panel = panel ?? make()
        self.panel = panel
        content.mode = mode
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
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A window shadow would outline the whole canvas; the capsule draws its own.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: HUDView(state: content)
            .padding(.bottom, Self.shadowRoom)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .bottom))
        // The content never sizes the window, either (1.3.1).
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Above the Dock on the screen the pointer is on, centered. Moves the canvas, never resizes it.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(x: (visible.midX - Self.canvas.width / 2).rounded(),
                             y: visible.minY + 56 - Self.shadowRoom)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

final class HUDState: ObservableObject {
    enum Mode: Equatable {
        /// Hidden: nothing that animates.
        case idle
        case listening
        case recognizing
        case message(String, symbol: String)
    }

    /// Recent input levels, oldest first: the newest drives the middle bar.
    static let levelCount = 6

    @Published var mode = Mode.idle
    @Published var levels: [Float] = Array(repeating: 0, count: levelCount)
}

private struct HUDView: View {
    @ObservedObject var state: HUDState

    /// Listening and Recognizing are one pill holding the same bars; a message gets a rounded rectangle
    /// that fits two lines. 120 × 40 since 1.14.0: at 79 × 32 Max found it too small (2026-10-18).
    static let pillHeight: CGFloat = 40
    static let messageHeight: CGFloat = 40

    private var showsMessage: Bool {
        if case .message = state.mode { return true }
        return false
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: showsMessage ? 18 : Self.pillHeight / 2, style: .continuous)
        HStack(spacing: 8) {
            switch state.mode {
            case .idle:
                EmptyView()
            // One case for both, so the bars are the same view when Recognizing takes over: they stop
            // following the voice and swell on their own, in place.
            case .listening, .recognizing:
                Waveform(levels: state.levels, working: state.mode == .recognizing)
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
        .padding(.horizontal, showsMessage ? 16 : 18)
        .padding(.vertical, showsMessage ? 9 : 0)
        .frame(minHeight: showsMessage ? Self.messageHeight : Self.pillHeight)
        // The same near-black on any wallpaper or window, in light and dark mode: glass took its tone from
        // what was behind it, and over a dark window in light mode the bars came out grey (1.11.0).
        .background(shape.fill(Color(white: 0.07).opacity(0.88)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
        .environment(\.colorScheme, .dark)
    }
}

/// The bars, listening or working.
///
/// Listening: mirrored about the center, the newest level in the middle bar and each older one a bar further
/// out, 12 % lower and 10 % fainter, so speech ripples outward. Working (Recognizing): the same bars stop
/// following the voice and swell slowly on their own, the middle first, until the HUD hides.
///
/// Layers, not SwiftUI shapes: the swell runs forever, and a running SwiftUI animation asks the hosting view for
/// another update every frame. When that landed in the constraints pass of a resizing panel, AppKit counted
/// each request as one more pass (1.4.4, see `HUD`). A layer animation runs in the render server and never
/// touches the view graph. Not `ProgressView` either, for the spinner this replaced: an `NSProgressIndicator`
/// draws off its layout box (≤1.4.3).
private struct Waveform: NSViewRepresentable {
    let levels: [Float]
    let working: Bool

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        if working { view.work() } else { view.show(levels) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformView, context: Context) -> CGSize? {
        WaveformView.size
    }
}

private final class WaveformView: NSView {
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 5
    static let barCount = HUDState.levelCount * 2 - 1
    static let size = CGSize(width: CGFloat(barCount) * (barWidth + spacing) - spacing, height: 22)
    /// The swell's range, inside the 22 pt the voice can reach.
    static let restHeight: CGFloat = 5
    static let swellHeight: CGFloat = 14

    private var bars: [CALayer] = []
    private var working = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<Self.barCount {
            let bar = CALayer()
            // The pill is near-black in every appearance, so the bars are plain white.
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.opacity = 1 - 0.1 * Float(Self.distance(index))
            bar.bounds.size = CGSize(width: Self.barWidth, height: Self.barWidth)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    private static func distance(_ index: Int) -> Int { abs(index - (HUDState.levelCount - 1)) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        withoutImplicitAnimation {
            for (index, bar) in bars.enumerated() {
                // Heights change about the default anchor point, so each bar grows up and down from the middle.
                bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                                       y: bounds.midY)
            }
        }
    }

    func show(_ levels: [Float]) {
        working = false
        swell()
        withoutImplicitAnimation {
            for (index, bar) in bars.enumerated() {
                let distance = Self.distance(index)
                let level = levels[levels.count - 1 - distance] * (1 - 0.12 * Float(distance))
                // Explicit, from where the bar is on screen: levels arrive every 50 ms, sooner than the 80 ms
                // glide, and an implicit action would restart from the last target and jump.
                let glide = CABasicAnimation(keyPath: "bounds.size.height")
                glide.fromValue = bar.presentation()?.bounds.size.height ?? bar.bounds.size.height
                glide.duration = 0.08
                glide.timingFunction = CAMediaTimingFunction(name: .linear)
                bar.bounds.size.height = max(Self.barWidth, CGFloat(level) * Self.size.height)
                bar.add(glide, forKey: "glide")
            }
        }
    }

    func work() {
        working = true
        swell()
    }

    /// Starts or stops the swell to match `working`, and only while the view is in a window: SwiftUI may ask
    /// for Recognizing before it has put a new view on screen, and a view out of a window must not animate.
    private func swell() {
        guard working, window != nil else {
            bars.forEach { $0.removeAnimation(forKey: "swell") }
            return
        }
        guard bars.first?.animation(forKey: "swell") == nil else { return }
        let now = CACurrentMediaTime()
        withoutImplicitAnimation {
            for (index, bar) in bars.enumerated() {
                bar.removeAnimation(forKey: "glide")
                bar.bounds.size.height = Self.restHeight
                let height = CABasicAnimation(keyPath: "bounds.size.height")
                height.fromValue = Self.restHeight
                height.toValue = Self.swellHeight
                height.duration = 0.9
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = bar.opacity * 0.55
                fade.toValue = bar.opacity
                fade.duration = 0.9
                let group = CAAnimationGroup()
                group.animations = [height, fade]
                group.duration = 0.9
                group.autoreverses = true
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // The middle bar leads; each one further out follows 0.12 s later, held at rest until then.
                group.beginTime = bar.convertTime(now, from: nil) + 0.12 * Double(Self.distance(index))
                group.fillMode = .backwards
                bar.add(group, forKey: "swell")
            }
        }
    }

    // The view leaves the window when the HUD goes back to .idle, and nothing animates after that; a view that
    // arrives in the window already Recognizing starts its swell here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        swell()
    }

    /// The bars are plain sublayers, so every property change would otherwise animate over 0.25 s.
    private func withoutImplicitAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

