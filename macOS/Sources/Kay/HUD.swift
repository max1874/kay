import AppKit
import SwiftUI

/// The glass capsule above the Dock while you dictate. It never takes focus or clicks: the text is
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
        } completionHandler: { [content] in
            // A dictation that began during the fade has already brought the panel back.
            guard panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            // An ordered-out panel keeps its views running: left on .recognizing, the spinner went on
            // animating after every dictation (≈15 % CPU, 1.4.2); left on .listening, the clock ticked.
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
        case listening(since: Date)
        case recognizing
        case message(String, symbol: String)
    }

    static let barCount = 14

    @Published var mode = Mode.idle
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
}

private struct HUDView: View {
    @ObservedObject var state: HUDState

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            switch state.mode {
            case .idle:
                EmptyView()
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
                        .frame(width: 36, alignment: .leading)  // the clock ticking must not resize the capsule
                }
            case .recognizing:
                Spinner()
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
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

/// The Recognizing spinner: an arc that Core Animation turns, exactly its 14 pt frame.
///
/// Not `ProgressView`: that is an `NSProgressIndicator` whose drawing doesn't line up with its layout box,
/// so the circle sat off center (≤1.4.3). Not a SwiftUI `repeatForever` animation either: a running SwiftUI
/// animation asks the hosting view for another update every frame, and when that landed in the constraints
/// pass of a resizing panel, AppKit counted each request as one more pass (see `HUD`). A layer animation runs
/// in the render server and never touches the view graph.
private struct Spinner: NSViewRepresentable {
    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 14)
    }
}

private final class SpinnerView: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        withoutImplicitAnimation {
            arc.frame = bounds  // turns about its center: the default anchor point
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: arc.lineWidth / 2, dy: arc.lineWidth / 2),
                              transform: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutImplicitAnimation { arc.strokeColor = NSColor.secondaryLabelColor.cgColor }
        }
    }

    /// `arc` is a plain sublayer, so every property change would otherwise fade in over 0.25 s.
    private func withoutImplicitAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    // Turning only while on screen: the view leaves the window when the HUD goes back to .idle.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            arc.removeAllAnimations()
            return
        }
        viewDidChangeEffectiveAppearance()
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi  // clockwise: the layer's y axis points up
        turn.duration = 0.8
        turn.repeatCount = .infinity
        arc.add(turn, forKey: "turn")
    }
}

/// Bars for recent input levels, newest on the right.
private struct LevelBars: View {
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
