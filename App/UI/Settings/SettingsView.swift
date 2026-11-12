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
    @ObservedObject private var webServer = WebFileServer.shared
    @ObservedObject private var pairing = PairingController.shared

    @State private var isShowingSetup = false

    var body: some View {
        List {
            accessSection
            dataSection
            shareSection
            interfaceSection
            browserSection
            aboutSection
        }
        .navigationTitle(L.t("Cài đặt", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSetup) {
            OnboardingView(isReview: true)
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
                FileBrowserView(root: ContainerRecord(
                    identifier: "System Data",
                    kind: .application,
                    path: "/private/var/containers/Data/System"
                ))
            } label: {
                Label("System Data", systemImage: "internaldrive")
            }
            NavigationLink {
                FileBrowserView(root: ContainerRecord(
                    identifier: "System Groups",
                    kind: .application,
                    path: "/private/var/mobile/Containers/Shared/SystemGroup"
                ))
            } label: {
                Label("System Groups", systemImage: "square.stack.3d.up")
            }
            NavigationLink {
                FavoritesView()
            } label: {
                Label(L.t("Yêu thích & Gần đây", "Favorites & Recents"), systemImage: "star")
            }
            NavigationLink {
                ShellConsoleView()
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            Button(role: .destructive) {
                // Quét lại từ đầu: xoá index database + mốc quét để lần sau
                // dò lại đủ (dùng khi danh sách thiếu app).
                LaunchServicesIndex.shared.invalidate()
                UserDefaults.standard.removeObject(forKey: "bbbbbb.containerScanVersion")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.bundleScanVersion")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.bundleScanUnsupported")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.containerScanCompletedAt")
                Log.info("Settings: đã xoá cache quét — mở danh sách để quét lại", category: .app)
            } label: {
                Label(L.t("Quét lại từ đầu", "Rescan from scratch"), systemImage: "arrow.clockwise")
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

    // MARK: - Chia sẻ qua LAN

    private var shareSection: some View {
        Section {
            Toggle(L.t("WebDAV/HTTP server", "WebDAV/HTTP server"), isOn: Binding(
                get: { webServer.isRunning },
                set: { enabled in
                    if enabled {
                        webServer.start()
                    } else {
                        webServer.stop()
                    }
                }
            ))
            if webServer.isRunning {
                LabeledContent(L.t("Địa chỉ", "Address"), value: "http://bbbbbb.local:\(webServer.port)")
                LabeledContent(L.t("Đăng nhập", "Login"), value: "mobile / bbbbbb")
            }
            if let error = webServer.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Label(L.t("Chia sẻ qua LAN", "LAN sharing"), systemImage: "wifi")
        } footer: {
            Text(L.t(
                "Chỉ chạy khi app đang mở. Mở trong Safari/trình duyệt cùng mạng Wi-Fi.",
                "Runs only while the app is open. Open it in a browser on the same Wi-Fi."
            ))
            .font(.footnote)
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
