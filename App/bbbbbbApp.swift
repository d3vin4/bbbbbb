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
    @State private var didLogLaunch = false

    var body: some View {
        Group {
            if hasCompletedSetup {
                AppsView()
            } else {
                OnboardingView()
            }
        }
        .environment(\.locale, AppLanguage.current.locale)
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
