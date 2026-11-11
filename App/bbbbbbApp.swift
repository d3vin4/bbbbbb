import SwiftUI

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
}
