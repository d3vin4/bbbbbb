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

    /// App hệ thống (Apple) hay app người dùng.
    var isSystem: Bool { bundleID.hasPrefix("com.apple.") }
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
    private var isFetchingIcons = false
    private static let lastScanKey = "bbbbbb.containerScanCompletedAt"
    private static let scanVersionKey = "bbbbbb.containerScanVersion"
    private static let currentScanVersion = 2
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

        // 1) Database ứng dụng của iOS (LaunchServices csstore): tên + container
        //    path cho mọi app — không cần quét từng container (đọc 1 lần, nhớ lại).
        let lsEntries = await Task.detached { LaunchServicesIndex.shared.entries() }.value
        Log.info("AppCatalog: database iOS → \(lsEntries.count) ứng dụng", category: .app)

        // 2) LaunchServices API (nếu máy cho phép) — bổ sung icon.
        //    Chạy trên main — API này không an toàn đa luồng, và rất nhanh.
        let installed = InstalledAppsProbe.installedApps()

        // 3) Container engine: enumerate nhanh (MHA-C2) để có sẵn đường dẫn.
        var records: [ContainerRecord] = []
        if DirectEngine.shared.capabilityReport().mcmAvailable {
            records = (try? await Task.detached { try DirectEngine.shared.fetchApplicationsFast(limit: 600) }.value) ?? []
        }

        if !lsEntries.isEmpty || !installed.isEmpty || !records.isEmpty {
            rebuild(installed: installed, records: records, lsEntries: lsEntries)
            state = .loaded
            saveCatalogCache()
        } else {
            state = .failed(L.t("Không liệt kê được ứng dụng nào.", "Could not list any app."))
        }

        // 3) Nếu chọn AirLift: tên + icon từ InstallationProxy.
        if AccessMethod.current == .airlift {
            await mergeAirliftCatalog()
        }

        // 4) Icon còn thiếu: tải nền theo lô (tunnel ấm), hiện dần lên danh sách.
        startIconFetch()

        // 5) Quét sâu container (worse_query) + quét gói .app — chạy nền,
        //    bảo đảm danh sách đủ app kèm tên thật.
        startContainerScan()
        startBundleScan()
    }

    // MARK: - Icon (tải nền theo lô, cache đĩa)

    private func startIconFetch() {
        guard !isFetchingIcons, AirliftEngine.shared.hasPairing else { return }
        let missing = apps.map(\.bundleID).filter { icons[$0] == nil }
        guard !missing.isEmpty else { return }

        isFetchingIcons = true
        Task {
            var remaining = missing
            let batchSize = 40
            var failures = 0
            while !remaining.isEmpty {
                let batch = Array(remaining.prefix(batchSize))
                remaining.removeFirst(batch.count)
                let fetched = await AirliftServices.shared.fetchIcons(bundleIDs: batch)
                if fetched.isEmpty {
                    failures += 1
                    if failures >= 2 { break }
                    continue
                }
                failures = 0
                applyIcons(fetched)
            }
            isFetchingIcons = false
            Log.info("AppCatalog: icon còn thiếu \(remaining.count), đã có \(icons.count)", category: .airlift)
        }
    }

    private func applyIcons(_ fetched: [String: Data]) {
        for (bundleID, data) in fetched {
            guard let image = UIImage(data: data) else { continue }
            icons[bundleID] = image
            persistIcon(image, for: bundleID)
        }
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

    private func rebuild(installed: [InstalledAppInfo], records: [ContainerRecord], lsEntries: [LaunchServicesEntry]) {
        var byID: [String: CatalogApp] = [:]

        // Database iOS: nguồn chính (tên + container path).
        for entry in lsEntries {
            byID[entry.bundleID] = CatalogApp(
                bundleID: entry.bundleID,
                name: entry.name,
                version: "",
                type: entry.isExtension ? "Extension" : "Application",
                path: entry.containerPath,
                source: .direct
            )
        }

        for info in installed {
            if let existing = byID[info.bundleID] {
                byID[info.bundleID] = CatalogApp(
                    bundleID: existing.bundleID,
                    name: info.name,
                    version: existing.version,
                    type: existing.type,
                    path: existing.path,
                    source: .direct
                )
            } else {
                byID[info.bundleID] = CatalogApp(
                    bundleID: info.bundleID,
                    name: info.name,
                    version: "",
                    type: "Application",
                    path: nil,
                    source: .direct
                )
            }
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

    private func mergeBundles(_ bundles: [(bundleID: String, name: String)]) {
        var byID: [String: CatalogApp] = [:]
        for app in apps { byID[app.bundleID] = app }
        for bundle in bundles {
            if let existing = byID[bundle.bundleID] {
                byID[bundle.bundleID] = CatalogApp(
                    bundleID: existing.bundleID,
                    name: existing.name == existing.bundleID ? bundle.name : existing.name,
                    version: existing.version,
                    type: existing.type,
                    path: existing.path,
                    source: .direct
                )
            } else {
                byID[bundle.bundleID] = CatalogApp(
                    bundleID: bundle.bundleID,
                    name: bundle.name,
                    version: "",
                    type: "Application",
                    path: nil,
                    source: .direct
                )
            }
        }
        apps = sorted(byID)
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
        // Chỉ lấy danh sách (không chờ icon) — icon tải nền theo lô ở dưới.
        guard let catalog = try? await AirliftServices.shared.fetchAppCatalog(iconLimit: 0) else { return }

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

        // Database iOS đã cho container của phần lớn app → không cần quét
        // (đây là đường nhanh: bỏ hẳn quét inode).
        let appsWithPath = apps.filter { $0.path != nil }.count
        if appsWithPath >= 50, appsWithPath * 2 >= apps.count {
            Log.info("AppCatalog: database đã có container (\(appsWithPath)/\(apps.count)) — bỏ quét", category: .badquery)
            return
        }

        // Đã quét gần đây (và đúng phiên bản quét) → bỏ qua cho nhanh.
        let storedVersion = UserDefaults.standard.integer(forKey: Self.scanVersionKey)
        if storedVersion >= Self.currentScanVersion,
           let last = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date,
           Date().timeIntervalSince(last) < 3600,
           apps.contains(where: { $0.path != nil }) {
            Log.info("AppCatalog: bỏ qua quét container (vừa quét < 1 giờ)", category: .badquery)
            return
        }

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
            UserDefaults.standard.set(Date(), forKey: Self.lastScanKey)
            UserDefaults.standard.set(Self.currentScanVersion, forKey: Self.scanVersionKey)
            Log.info(
                "AppCatalog: quét xong — \(records.count) container, tổng \(apps.count) ứng dụng",
                category: .badquery
            )
        }
    }

    /// Quét gói .app — nguồn đủ app + tên thật (bundle luôn tồn tại).
    private func startBundleScan() {
        let storedVersion = UserDefaults.standard.integer(forKey: "bbbbbb.bundleScanVersion")
        if storedVersion >= 1, apps.count >= 50 { return }

        Task {
            let bundles = (try? await Task.detached { () -> [(bundleID: String, name: String)] in
                try DirectEngine.shared.fetchApplicationsFromBundles(limit: 600) { scanned, total in
                    if scanned % 20 == 0 {
                        Log.info("AppCatalog: quét bundle \(scanned)/\(total)", category: .badquery)
                    }
                }
            }.value) ?? []

            guard !bundles.isEmpty else {
                Log.info("AppCatalog: quét bundle không ra kết quả", category: .badquery)
                return
            }

            mergeBundles(bundles)
            saveCatalogCache()
            UserDefaults.standard.set(1, forKey: "bbbbbb.bundleScanVersion")
            Log.info("AppCatalog: bundle scan → \(bundles.count) app, tổng \(apps.count) ứng dụng", category: .badquery)
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
