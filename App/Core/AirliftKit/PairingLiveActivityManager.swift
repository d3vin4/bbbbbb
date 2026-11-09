import ActivityKit
import Foundation

/// Drives the “PIN pairing” Live Activity (Dynamic Island + Lock Screen) so the
/// 6-digit code stays visible while the user navigates to Settings.
@MainActor
final class PairingLiveActivityManager {
    private var activity: Activity<PairingActivityAttributes>?

    func start(deviceName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }
        do {
            let state = PairingActivityAttributes.ContentState(
                pin: "––––––",
                phaseLabel: "Pairing",
                detail: "Chuẩn bị mã PIN…"
            )
            activity = try Activity.request(
                attributes: PairingActivityAttributes(deviceName: deviceName),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            Log.info("Đã mở Live Activity pairing", category: .pairing)
        } catch {
            Log.warning("Không mở được Live Activity: \(error.localizedDescription)", category: .pairing)
        }
    }

    func update(pin: String, detail: String) {
        guard let activity else { return }
        let state = PairingActivityAttributes.ContentState(
            pin: pin,
            phaseLabel: "Mã PIN pairing",
            detail: detail
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end(success: Bool, detail: String) {
        guard let activity else { return }
        self.activity = nil
        let state = PairingActivityAttributes.ContentState(
            pin: success ? "OK" : "—",
            phaseLabel: success ? "Đã pair" : "Pairing dừng",
            detail: detail
        )
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now + 8)
            )
        }
    }
}
