import SwiftUI

@main
struct bbbbbbApp: App {
    @StateObject private var logStore = LogStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(logStore)
        }
    }
}

struct RootTabView: View {
    @State private var didLogLaunch = false

    var body: some View {
        TabView {
            AppsView()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
        }
        .task {
            guard !didLogLaunch else { return }
            didLogLaunch = true
            AirliftEngine.shared.prepare()
            Log.info(
                "bbbbbb khởi động — iOS \(SupportMatrix.currentOSVersion) (hỗ trợ \(SupportMatrix.supportSummary))",
                category: .app
            )
        }
    }
}
