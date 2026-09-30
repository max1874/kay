import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island while Kay dictates. Modeled on the system's own: Voice Memos (red
/// waveform and timer in the island) and Clock's timer (round buttons on the left, big figures on the right).
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Glyph(phase: state.phase)
                        .font(.title2)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .listening {
                        Clock(startedAt: state.startedAt)
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                            .frame(maxWidth: 110, alignment: .trailing)
                            .padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 14) {
                        Caption(state: state, lines: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if state.phase == .listening { StopButton(size: 48) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Glyph(phase: state.phase)
            } compactTrailing: {
                // Only listening and transcribing reach the island: an ended activity leaves it at once.
                if state.phase == .listening {
                    Clock(startedAt: state.startedAt)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
            } minimal: {
                Glyph(phase: state.phase)
            }
            .keylineTint(.red)
        }
    }
}

private struct LockScreenView: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .listening:
            HStack(alignment: .center, spacing: 16) {
                StopButton(size: 52)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Label("Kay", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Clock(startedAt: state.startedAt)
                        .font(.system(size: 44, weight: .light, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
        default:
            HStack(alignment: .center, spacing: 14) {
                Glyph(phase: state.phase)
                    .font(.title)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let message = state.message, state.phase != .recognizing {
                        Text(message)
                            .font(.body)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch state.phase {
        case .listening: "Listening"
        case .recognizing: "Transcribing…"
        case .copied: "Copied to clipboard"
        case .tapToCopy: "Tap to copy"
        case .failed: "Dictation failed"
        }
    }
}

/// One symbol per phase, in the colors the system uses for the same states.
private struct Glyph: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .listening: Image(systemName: "waveform").foregroundStyle(.red)
        case .recognizing: Image(systemName: "text.bubble").foregroundStyle(.secondary)
        case .copied: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .tapToCopy: Image(systemName: "doc.on.clipboard").foregroundStyle(.blue)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// The line under the island's top row.
private struct Caption: View {
    let state: DictationActivityAttributes.ContentState
    let lines: Int

    var body: some View {
        switch state.phase {
        case .listening:
            Text("Listening").font(.headline)
        case .recognizing:
            Text("Transcribing…").font(.headline).foregroundStyle(.secondary)
        case .copied, .tapToCopy, .failed:
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == .copied ? "Copied to clipboard" : state.phase == .tapToCopy ? "Tap to copy" : "Dictation failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.message ?? "")
                    .font(.callout)
                    .lineLimit(lines)
            }
        }
    }
}

/// The running clock, `.timer` style. With `Text(timerInterval: start...distantFuture)` instead the
/// Dynamic Island stopped showing (Lock Screen fine), 2026-09-30.
private struct Clock: View {
    let startedAt: Date

    var body: some View {
        Text(startedAt, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Voice Memos' red stop: ends the dictation and copies the text.
private struct StopButton: View {
    let size: CGFloat

    var body: some View {
        Button(intent: StopDictationIntent()) {
            ZStack {
                Circle().fill(.red.opacity(0.22))
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.red)
                    .frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}
