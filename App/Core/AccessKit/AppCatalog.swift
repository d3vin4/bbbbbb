import Combine
import Foundation
import UIKit

/// Ứng dụng đã cài, hợp nhất từ nhiều nguồn.
struct CatalogApp: Identifiable, Hashable, Codable {
    enum Source: String, Hashable, Codable {
        /// Giữ lại để cache cũ vẫn giải mã được.
        case airlift
        case direct
    }

    let bundleID: String
    let name: String
    let version: String
    let type: String
    let path: String?
    let source: Source

    var id: String { bundleID }
}

private struct CatalogCachePayload: Codable {
    let apps: [CatalogApp]
    let savedAt: Date
}

/// Nguồn dữ liệu cho danh sách ứng dụng.
///
/// - `LaunchServices`: danh sách app đã cài kèm tên + icon — tức thì, không cần
///   identity MHA, không cần tunnel.
/// - `Container engine`: MCM enumerate (nhanh, cần identity MHA) hoặc quét sâu
///   worse_query (class-7) để gắn đường dẫn container cho từng ứng dụng.
@MainActor
final class AppCatalog: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var apps: [CatalogApp] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var isScanningContainers = false
    @Published var searchText = ""

    private var didLoadOnce = false
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
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
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
        state = .loading

        // 1) Danh sách ứng dụng đã cài (LaunchServices): tức thì, có tên + icon.
        //    Chạy trên main — API này không an toàn đa luồng, và rất nhanh.
        let installed = InstalledAppsProbe.installedApps()
        Log.info("AppCatalog: LaunchServices → \(installed.count) ứng dụng", category: .app)

        // 2) Container engine: enumerate nhanh (MHA-C2) để có sẵn đường dẫn.
        var records: [ContainerRecord] = []
        if DirectEngine.shared.capabilityReport().mcmAvailable {
            records = (try? await Task.detached { try DirectEngine.shared.fetchApplicationsFast(limit: 600) }.value) ?? []
        }

        if !installed.isEmpty || !records.isEmpty {
            rebuild(installed: installed, records: records)
            state = .loaded
            saveCatalogCache()
        } else {
            state = .failed(L.t("Không liệt kê được ứng dụng nào.", "Could not list any app."))
        }

        // 3) Nếu chọn AirLift: tên + icon từ InstallationProxy.
        if AccessMethod.current == .airlift {
            await mergeAirliftCatalog()
        }

        // 4) Quét sâu container (worse_query) — chạy nền, bổ sung app + path.
        startContainerScan()
    }

    /// Gỡ cài đặt một ứng dụng (qua AirLift / InstallationProxy).
    func uninstall(_ app: CatalogApp) async throws {
        guard AirliftEngine.shared.hasPairing else {
            throw AirliftServicesError.failed(
                L.t("Gỡ cài đặt cần AirLift (đã pair thiết bị).", "Uninstall needs AirLift (paired device).")
            )
        }
        try await AirliftServices.shared.uninstall(bundleID: app.bundleID)
        apps.removeAll { $0.bundleID == app.bundleID }
        saveCatalogCache()
    }

    // MARK: - Dữ liệu

    private func rebuild(installed: [InstalledAppInfo], records: [ContainerRecord]) {
        var byID: [String: CatalogApp] = [:]

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

    private func mergePaths(_ records: [ContainerRecord]) {
        var byID: [String: CatalogApp] = [:]
        for app in apps { byID[app.bundleID] = app }
        for record in records {
            merge(record, into: &byID)
        }
        apps = sorted(byID)
    }

    private func mergeAirliftCatalog() async {
        guard AirliftEngine.shared.hasPairing else { return }
        guard let catalog = try? await AirliftServices.shared.fetchAppCatalog(iconLimit: 80) else { return }

        var byID: [String: CatalogApp] = [:]
        for app in apps { byID[app.bundleID] = app }

        for info in catalog.apps {
            let existing = byID[info.bundleID]
            byID[info.bundleID] = CatalogApp(
                bundleID: info.bundleID,
                name: info.name,
                version: info.version,
                type: info.type,
                // `info.path` là đường dẫn bundle (.app) — container dữ liệu
                // vẫn được resolve bằng worse_query khi mở.
                path: existing?.path,
                source: .airlift
            )
        }

        apps = sorted(byID)
        for (bundleID, data) in catalog.icons {
            guard let image = UIImage(data: data) else { continue }
            icons[bundleID] = image
            persistIcon(image, for: bundleID)
        }
        saveCatalogCache()
        Log.info("AppCatalog: AirLift → \(catalog.apps.count) ứng dụng", category: .airlift)
    }

    // MARK: - Quét container nền

    private func startContainerScan() {
        guard !isScanningContainers else { return }
        isScanningContainers = true

        Task {
            let records = try? await Task.detached { () -> [ContainerRecord] in
                try DirectEngine.shared.fetchApplicationsDeep(limit: 600) { scanned, total in
                    if scanned % 10 == 0 {
                        Log.info("AppCatalog: quét \(scanned)/\(total) container", category: .badquery)
                    }
                }
            }.value

            isScanningContainers = false

            guard let records, !records.isEmpty else {
                Log.info("AppCatalog: quét container không ra kết quả", category: .badquery)
                return
            }

            mergePaths(records)
            saveCatalogCache()
            Log.info(
                "AppCatalog: quét xong — \(records.count) container, tổng \(apps.count) ứng dụng",
                category: .badquery
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
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else {
                continue
            }
            icons[bundleID] = image
        }
    }

    // MARK: - Catalog cache (instant relaunch)

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
