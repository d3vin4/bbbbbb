import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LogStore

    var body: some View {
        List {
            Section("Logs") {
                LabeledContent("Số bản ghi", value: "\(store.entries.count)")
                Button(role: .destructive) {
                    store.clear()
                } label: {
                    Text("Xóa toàn bộ logs")
                }
            }

            Section("Phiên bản") {
                LabeledContent("Ứng dụng", value: Bundle.main.appVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
