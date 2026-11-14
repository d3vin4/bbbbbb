import SwiftUI

/// Cài đặt chia theo nhóm rõ ràng: Truy cập · Dữ liệu · Giao diện ·
/// Trình duyệt tệp · Về app.
struct SettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .english
    @AppStorage("bbbbbb.files.viewMode") private var filesViewMode = "list"
    @AppStorage(FileBrowserModel.showHiddenKey) private var filesShowHidden = false
    @AppStorage(FileBrowserModel.showExtensionsKey) private var filesShowExtensions = false
    @AppStorage(FileBrowserModel.sortKeyKey) private var filesSortKeyRaw = FileSortKey.name.rawValue
    @AppStorage(FileBrowserModel.sortAscendingKey) private var filesSortAscending = true

    @State private var isShowingSetup = false

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
            OnboardingView()
        }
    }

    // MARK: - Truy cập

    private var accessSection: some View {
        Section {
            LabeledContent(L.t("Container engine", "Container engine"), value: BQCore.routeDescription())
            LabeledContent(L.t("App Group", "App Group"), value: BQCore.appGroupIdentifiers().isEmpty
                ? L.t("Chưa có — cần ký kèm", "Missing — required for signing")
                : L.t("Đã có", "Present"))
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
                FileBrowserView(root: ContainerRecord(
                    identifier: "bbbbbb",
                    kind: .application,
                    path: NSHomeDirectory()
                ))
            } label: {
                Label(L.t("Container của app này", "This app's container"), systemImage: "folder.badge.person.crop")
            }
            Button(role: .destructive) {
                // Quét lại từ đầu: xoá index database + mốc quét để lần sau
                // dò lại đủ (dùng khi danh sách thiếu app).
                UserDefaults.standard.removeObject(forKey: "bbbbbb.containerScanVersion")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.bundleScanVersion")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.bundleScanUnsupported")
                UserDefaults.standard.removeObject(forKey: "bbbbbb.bundleOnlyScanDone")
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
