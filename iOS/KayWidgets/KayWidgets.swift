import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct KayWidgets: WidgetBundle {
    var body: some Widget {
        DictationControl()
        DictationLiveActivity()
    }
}

/// The button people put on the Action Button, in Control Center or on the Lock Screen.
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.max1874.kay.dictate") {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Dictate", systemImage: "waveform")
            }
        }
        .displayName("Dictate with Kay")
        .description("Press to start, press again to stop. The text is copied to the clipboard.")
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state).font(.title3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PhaseText(state: context.state)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Elapsed(state: context.state)
                    .frame(maxWidth: 44)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PhaseIcon(phase: state.phase)
                .font(.title)
                .frame(width: 36)
            PhaseText(state: state)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Elapsed(state: state).font(.title3)
        }
    }
}

private struct PhaseIcon: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .listening: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .recognizing: Image(systemName: "waveform").foregroundStyle(.blue)
        case .copied: Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct PhaseText: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .listening: Text("Listening… press again to stop")
        case .recognizing: Text("Recognizing…")
        case .copied: Text(state.message ?? "").foregroundStyle(.primary)
        case .failed: Text(state.message ?? "").foregroundStyle(.secondary)
        }
    }
}

/// The clock while listening; nothing once it stopped.
private struct Elapsed: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .listening {
            Text(state.startedAt, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else if state.phase == .copied {
            Text("Copied").font(.caption.weight(.semibold)).foregroundStyle(.green)
        }
    }
}
