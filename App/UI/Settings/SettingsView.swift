import SwiftUI

/// Cài đặt chia theo nhóm rõ ràng: Truy cập · Dữ liệu · Giao diện ·
/// Trình duyệt tệp · Về app.
struct SettingsView: View {
    @AppStorage(AccessMethod.storageKey) private var accessMethod: AccessMethod = .direct
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .english
    @AppStorage("bbbbbb.files.viewMode") private var filesViewMode = "list"
    @AppStorage(FileBrowserModel.showHiddenKey) private var filesShowHidden = false
    @AppStorage(FileBrowserModel.showExtensionsKey) private var filesShowExtensions = false
    @AppStorage(FileBrowserModel.sortKeyKey) private var filesSortKeyRaw = FileSortKey.name.rawValue
    @AppStorage(FileBrowserModel.sortAscendingKey) private var filesSortAscending = true

    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var pairing = PairingController.shared

    @State private var isShowingSetup = false
    @State private var isShowingInstall = false

    var body: some View {
        List {
            accessSection
            dataSection
            interfaceSection
            browserSection
            aboutSection
        }
        .navigationTitle(L.t("Cài đặt", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSetup) {
            OnboardingView(isReview: true)
        }
        .sheet(isPresented: $isShowingInstall) {
            InstallIPAView()
        }
        .task {
            await tunnel.load()
        }
    }

    // MARK: - Truy cập

    private var accessSection: some View {
        Section {
            Picker(L.t("Nguồn danh sách app", "App list source"), selection: $accessMethod) {
                ForEach(AccessMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.menu)

            LabeledContent(L.t("Container engine", "Container engine"), value: BQCore.routeSummary())

            Text(L.t(
                "Container của ứng dụng luôn mở bằng worse_query (mặc định, không cần chỉnh).",
                "App containers always open with worse_query (default, nothing to configure)."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            if accessMethod == .airlift {
                LabeledContent(L.t("Pairing", "Pairing")) {
                    Text(pairing.hasPairingFile ? L.t("Đã pair", "Paired") : L.t("Chưa pair", "Not paired"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L.t("Tunnel", "Tunnel")) {
                    Text(tunnel.statusDescription)
                        .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
                }
                Button {
                    isShowingSetup = true
                } label: {
                    Label(L.t("Hướng dẫn thiết lập", "Setup guide"), systemImage: "list.number")
                }
            }
        } header: {
            Label(L.t("Truy cập", "Access"), systemImage: "lock.shield")
        }
    }

    // MARK: - Dữ liệu

    private var dataSection: some View {
        Section {
            NavigationLink {
                AppGroupsView()
            } label: {
                Label("App Groups", systemImage: "rectangle.3.group")
            }
            NavigationLink {
                FavoritesView()
            } label: {
                Label(L.t("Yêu thích & Gần đây", "Favorites & Recents"), systemImage: "star")
            }
            Button {
                isShowingInstall = true
            } label: {
                Label(L.t("Cài ứng dụng (.ipa)", "Install app (.ipa)"), systemImage: "square.and.arrow.down")
            }
        } header: {
            Label(L.t("Dữ liệu", "Data"), systemImage: "internaldrive")
        }
    }

    // MARK: - Giao diện

    private var interfaceSection: some View {
        Section {
            Picker(L.t("Ngôn ngữ", "Language"), selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Label(L.t("Giao diện", "Interface"), systemImage: "globe")
        }
    }

    // MARK: - Trình duyệt tệp

    private var browserSection: some View {
        Section {
            Picker(L.t("Kiểu xem", "View"), selection: $filesViewMode) {
                Text(L.t("Danh sách", "List")).tag("list")
                Text(L.t("Lưới", "Grid")).tag("grid")
            }
            .pickerStyle(.menu)
            Toggle(L.t("Hiện file ẩn", "Show hidden files"), isOn: $filesShowHidden)
            Toggle(L.t("Hiện phần mở rộng", "Show extensions"), isOn: $filesShowExtensions)
            Picker(L.t("Sắp xếp mặc định", "Default sort"), selection: $filesSortKeyRaw) {
                ForEach(FileSortKey.allCases) { key in
                    Text(key.title).tag(key.rawValue)
                }
            }
            .pickerStyle(.menu)
            Toggle(L.t("Sắp xếp tăng dần", "Sort ascending"), isOn: $filesSortAscending)
        } header: {
            Label(L.t("Trình duyệt tệp", "File browser"), systemImage: "folder")
        }
    }

    // MARK: - Về app

    private var aboutSection: some View {
        Section {
            LabeledContent(L.t("Ứng dụng", "App"), value: Bundle.main.appVersion)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
        } header: {
            Label(L.t("Về bbbbbb", "About"), systemImage: "info.circle")
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
