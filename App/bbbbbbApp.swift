import SwiftUI
import UserNotifications

@main
struct bbbbbbApp: App {
    @StateObject private var logStore = LogStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(logStore)
        }
    }
}

/// Điểm vào: lần đầu mở → màn thiết lập, sau đó → danh sách ứng dụng.
struct RootView: View {
    @AppStorage(onboardingCompletedKey) private var hasCompletedSetup = false
    @ObservedObject private var pairing = PairingController.shared
    @State private var didLogLaunch = false
    @State private var isShowingPINAlert = false

    var body: some View {
        Group {
            if hasCompletedSetup {
                AppsView()
            } else {
                OnboardingView()
            }
        }
        .environment(\.locale, AppLanguage.current.locale)
        // Emergency pop up ở tầng gốc: mã PIN hiện ra là bật, bất kể đang ở
        // màn nào trong app (không phụ thuộc màn onboarding còn mở hay không).
        .onChange(of: pairing.pairingPIN) { _, newValue in
            isShowingPINAlert = newValue != nil
            // Banner hệ thống: alert của SwiftUI không present được khi đang mở
            // sheet (màn onboarding) — thông báo thì luôn nổi lên được.
            if let pin = newValue { Self.postPINNotification(pin) }
        }
        .alert(
            pairing.pairingPIN.map { "PIN: \($0)" } ?? L.t("Mã PIN pairing", "Pairing PIN"),
            isPresented: $isShowingPINAlert
        ) {
            Button(L.t("Sao chép", "Copy")) {
                if let pin = pairing.pairingPIN {
                    UIPasteboard.general.string = pin
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(L.t(
                "Nhập mã này trong Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb.",
                "Enter this code in Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb."
            ))
        }
        .task {
            guard !didLogLaunch else { return }
            didLogLaunch = true
            Log.info(
                "bbbbbb khởi động — iOS \(SupportMatrix.currentOSVersion) (hỗ trợ \(SupportMatrix.supportSummary))",
                category: .app
            )
        }
    }

    /// Thông báo ngay lập tức với mã PIN (hoạt động cả khi app đang mở sheet).
    private static func postPINNotification(_ pin: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PIN pairing: \(pin)"
            content.body = "Nhập mã này trong Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "bbbbbb.pairing.pin", content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
