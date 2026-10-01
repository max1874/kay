import AppKit
import SwiftUI

/// The glass capsule above the Dock while you dictate. It never takes focus or clicks: the text is
/// about to land in whatever app you are typing in, and that app has to stay frontmost.
final class HUD {
    private let content = HUDState()
    /// Measures the capsule for the current mode. `NSView.fittingSize` is the *smallest* size that fits, and
    /// SwiftUI lets text shrink to nothing: "Recognizing…" was laid out 0 pt wide, leaving a 60 pt capsule
    /// with the spinner off to one side (1.4.2–1.4.3). This asks for the size the content wants instead.
    private lazy var measure = NSHostingController(rootView: HUDView(state: content))
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
        place(panel, size: measure.sizeThatFits(in: CGSize(width: 560, height: 240)))
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
        // Kay sizes the panel itself, once per mode. Left to the hosting view, every level update
        // (20 a second) re-derived the window's size limits inside the constraints pass until AppKit
        // gave up and threw — 1.3.1 crashed on letting go of the key.
        host.sizingOptions = []
        // The window shadow follows the layer; unclipped, it would box the capsule in grey.
        host.wantsLayer = true
        host.layer?.cornerRadius = HUDView.height / 2
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        return panel
    }

    /// Above the Dock on the screen the pointer is on, centered; size and position in one step.
    private func place(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        panel.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 56,
                              width: size.width, height: size.height), display: true)
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
    }
}

/// The Recognizing spinner: an arc that Core Animation turns, exactly its 14 pt frame.
///
/// Not `ProgressView`: that is an `NSProgressIndicator` whose drawing doesn't line up with its layout box,
/// so the circle sat off center (≤1.4.3). Not a SwiftUI `repeatForever` animation either: a running SwiftUI
/// animation asks the hosting view for another update every frame, and when that landed in the constraints
/// pass of the panel being resized for this mode, AppKit counted each request as one more pass and threw.
/// 1.4.4–1.5.1 crashed that way on every letting go of the key, losing the dictation with the process.
/// A layer animation runs in the render server and never touches the view graph.
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
