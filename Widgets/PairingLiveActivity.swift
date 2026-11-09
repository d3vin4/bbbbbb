import ActivityKit
import SwiftUI
import WidgetKit

struct PairingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            PairingLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 6) {
                        Text("Mã pairing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(context.state.pin)
                            .font(.system(size: 42, weight: .bold, design: .monospaced))
                        Text(context.state.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "link")
            } compactTrailing: {
                Text(context.state.pin)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            } minimal: {
                Image(systemName: "link")
            }
            .keylineTint(.cyan)
        }
    }
}

private struct PairingLockScreenView: View {
    let context: ActivityViewContext<PairingActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            Text(context.state.phaseLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(context.state.pin)
                .font(.system(size: 46, weight: .bold, design: .monospaced))
            Text(context.state.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .multilineTextAlignment(.center)
    }
}

@main
struct PairingActivityBundle: WidgetBundle {
    var body: some Widget {
        PairingLiveActivity()
    }
}
