import Combine
import Foundation
import UIKit

/// Ứng dụng trong danh sách.
struct CatalogApp: Identifiable, Hashable, Codable {
    enum Source: String, Hashable, Codable {
        case direct
    }

    let bundleID: String
    let name: String
    let version: String
    let type: String
    let path: String?
    let source: Source

    var id: String { bundleID }

    /// App hệ thống (Apple) hay app người dùng.
    var isSystem: Bool { bundleID.hasPrefix("com.apple.") }
}

private struct CatalogCachePayload: Codable {
    let apps: [CatalogApp]
    let savedAt: Date
}

/// Danh sách ứng dụng cho màn chính.
///
/// - Tên + icon: đọc từ LaunchServices (hệ thống cho phép).
/// - Container path: quét bằng worse_query + fsgetpath (chạy nền).
@MainActor
final class AppCatalog: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum AppFilter: String, CaseIterable, Identifiable {
        case all
        case user
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L.t("Tất cả", "All")
            case .user: return L.t("Người dùng", "User")
            case .system: return L.t("Hệ thống", "System")
            }
        }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var apps: [CatalogApp] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var isScanningContainers = false
    @Published var filter: AppFilter = .all
    @Published var searchText = ""

    private var didLoadOnce = false
    private var isReloading = false
    private static let lastScanKey = "bbbbbb.containerScanCompletedAt"
    private static let scanVersionKey = "bbbbbb.containerScanVersion"
    private static let currentScanVersion = 3
    private let iconDirectory: URL
    private let cacheFileURL: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        iconDirectory = caches.appendingPathComponent("AppIcons", isDirectory: true)
        cacheFileURL = caches.appendingPathComponent("AppCatalogCache.json")
        try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        loadCachedIcons()
        loadCatalogCache()
    }

    var filteredApps: [CatalogApp] {
        var list: [CatalogApp]
        switch filter {
        case .all: list = apps
        case .user: list = apps.filter { !$0.isSystem }
        case .system: list = apps.filter { $0.isSystem }
        }
        guard !searchText.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    func reloadIfNeeded() async {
        guard !didLoadOnce else { return }
        didLoadOnce = true
        await reload()
    }

    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        state = .loading

        // Danh sách + tên + icon từ LaunchServices (tức thì).
        let installed = await Task.detached { InstalledAppsProbe.installedApps() }.value
        Log.info("AppCatalog: LaunchServices → \(installed.count) ứng dụng", category: .app)

        if !installed.isEmpty {
            rebuild(installed: installed, records: [])
            state = .loaded
            saveCatalogCache()
        } else if !apps.isEmpty {
            state = .loaded
        } else {
            state = .failed(L.t("Không liệt kê được ứng dụng nào.", "Could not list any app."))
        }

        startContainerScan()
    }

    // MARK: - Dữ liệu

    private func rebuild(installed: [InstalledAppInfo], records: [ContainerRecord]) {
        var byID: [String: CatalogApp] = [:]
        for app in apps { byID[app.bundleID] = app }

        for info in installed {
            byID[info.bundleID] = CatalogApp(
                bundleID: info.bundleID,
                name: info.name,
                version: "",
                type: "Application",
                path: nil,
                source: .direct
            )
            if let icon = info.icon {
                icons[info.bundleID] = icon
                persistIcon(icon, for: info.bundleID)
            }
        }

        for record in records {
            merge(record, into: &byID)
        }

        apps = sorted(byID)
    }

    private func merge(_ record: ContainerRecord, into byID: inout [String: CatalogApp]) {
        let path = record.path.isEmpty ? nil : record.path
        if let existing = byID[record.identifier] {
            byID[record.identifier] = CatalogApp(
                bundleID: existing.bundleID,
                name: existing.name,
                version: existing.version,
                type: existing.type,
                path: existing.path ?? path,
                source: .direct
            )
        } else {
            byID[record.identifier] = CatalogApp(
                bundleID: record.identifier,
                name: record.identifier,
                version: "",
                type: record.kind.title,
                path: path,
                source: .direct
            )
        }
    }

    private func sorted(_ byID: [String: CatalogApp]) -> [CatalogApp] {
        byID.values.sorted {
            $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending
        }
    }

    // MARK: - Quét container (nền)

    private func startContainerScan() {
        guard !isScanningContainers else { return }

        let storedVersion = UserDefaults.standard.integer(forKey: Self.scanVersionKey)
        if storedVersion >= Self.currentScanVersion,
           let last = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date,
           Date().timeIntervalSince(last) < 3600,
           apps.contains(where: { $0.path != nil }) {
            Log.info("AppCatalog: bỏ qua quét container (vừa quét < 1 giờ)", category: .worseQuery)
            return
        }

        isScanningContainers = true

        Task {
            let records = try? await Task.detached { () -> [ContainerRecord] in
                try DirectEngine.shared.fetchApplicationsDeep(limit: 600) { scanned, total in
                    if scanned % 25 == 0 {
                        Log.info("AppCatalog: quét \(scanned)/\(total) container", category: .worseQuery)
                    }
                }
            }.value

            isScanningContainers = false

            guard let records, !records.isEmpty else {
                Log.info("AppCatalog: quét container không ra kết quả", category: .worseQuery)
                return
            }

            var byID: [String: CatalogApp] = [:]
            for app in apps { byID[app.bundleID] = app }
            for record in records { merge(record, into: &byID) }

            // App hệ thống không có container: chỉ có tên gói (fsgetpath).
            var existingNames = Set(byID.values.map(\.name))
            var added = 0
            for item in await Task.detached {
                DirectEngine.shared.fetchBundleOnlyNames(limit: 200)
            }.value {
                guard !existingNames.contains(item.name) else { continue }
                existingNames.insert(item.name)
                byID["bundle:\(item.name)"] = CatalogApp(
                    bundleID: "bundle:\(item.name)",
                    name: item.name,
                    version: "",
                    type: "System",
                    path: item.path,
                    source: .direct
                )
                added += 1
            }

            apps = sorted(byID)
            saveCatalogCache()
            UserDefaults.standard.set(Date(), forKey: Self.lastScanKey)
            UserDefaults.standard.set(Self.currentScanVersion, forKey: Self.scanVersionKey)
            Log.info(
                "AppCatalog: quét xong — \(records.count) container, +\(added) app hệ thống, tổng \(apps.count) ứng dụng",
                category: .worseQuery
            )
        }
    }

    // MARK: - Icon cache

    private func persistIcon(_ image: UIImage, for bundleID: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: iconDirectory.appendingPathComponent("\(bundleID).png"), options: .atomic)
    }

    private func loadCachedIcons() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: iconDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "png" {
            let bundleID = file.deletingPathExtension().lastPathComponent
            guard icons[bundleID] == nil else { continue }
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            icons[bundleID] = image
        }
    }

    // MARK: - Catalog cache (mở lại là có ngay)

    private func saveCatalogCache() {
        let payload = CatalogCachePayload(apps: apps, savedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private func loadCatalogCache() {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let payload = try? JSONDecoder().decode(CatalogCachePayload.self, from: data),
              !payload.apps.isEmpty else { return }
        apps = payload.apps
        state = .loaded
        Log.info("AppCatalog: nạp cache \(payload.apps.count) ứng dụng", category: .app)
    }
}
