import Combine
import Foundation
import UIKit

/// App đã cài, hợp nhất từ hai engine (AirLift / Trực tiếp).
struct CatalogApp: Identifiable, Hashable, Codable {
    enum Source: String, Hashable, Codable {
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

/// Nguồn dữ liệu cho tab Apps: danh sách ứng dụng + icon (cache trên đĩa).
///
/// Tối ưu tốc độ:
/// - `Tự động`: liệt kê tức thì bằng một lệnh MCM (không resolve container path),
///   icon tải nền qua AirLift, và cache JSON để lần mở sau hiện ngay.
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
        switch AccessMethod.current {
        case .auto:
            await reloadAuto()
        case .direct:
            await reloadDirect()
        case .airlift:
            await reloadAirlift()
        }
    }

    func uninstall(_ app: CatalogApp) async throws {
        guard app.source == .airlift else {
            throw AirliftServicesError.failed("Gỡ cài đặt cần cơ chế AirLift.")
        }
        try await AirliftServices.shared.uninstall(bundleID: app.bundleID)
        apps.removeAll { $0.bundleID == app.bundleID }
        saveCatalogCache()
    }

    // MARK: - Auto (fastest)

    private func reloadAuto() async {
        let report = DirectEngine.shared.capabilityReport()
        if report.mcmAvailable {
            // Đường nhanh: một lệnh MCM → hiện ngay; nếu daemon từ chối và có
            // App Group, tự chuyển sang worse_query map bên dưới.
            if await loadDirectFast(report: report) {
                scheduleIconRefresh()
                return
            }
        }
        if AirliftEngine.shared.hasPairing {
            await reloadAirlift()
            return
        }
        state = .failed("Không có engine nào sẵn sàng (MCM \(report.mcmAvailable ? "OK" : "thiếu"), identity \(report.mhaIdentity ? "đúng" : "chưa đúng")). Mở “Kiểm tra tương thích” để xem hướng dẫn.")
    }

    /// Icons qua AirLift chạy nền — không chặn danh sách.
    private func scheduleIconRefresh() {
        guard AirliftEngine.shared.hasPairing else { return }
        let missing = apps.map(\.bundleID).filter { icons[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            await TunnelManager.shared.load()
            guard TunnelManager.shared.isConnected else {
                Log.info("AppCatalog: bỏ qua tải icon qua AirLift (tunnel chưa kết nối)", category: .airlift)
                return
            }
            let batch = Array(missing.prefix(80))
            let fetched = await AirliftServices.shared.fetchIcons(bundleIDs: batch)
            applyIcons(fetched)
        }
    }

    /// iOS 26+ có thể ẩn app khỏi enumerate — merge thêm từ LaunchServices store.
    private func scheduleLaunchServicesMerge() {
        guard DirectEngine.shared.capabilityReport().mcmAvailable else { return }
        Task {
            let records = try? await Task.detached {
                try DirectEngine.shared.fetchApplicationsViaLaunchServices(limit: 600)
            }.value
            guard let records, !records.isEmpty else { return }

            let existing = Set(apps.map(\.bundleID))
            let additions = records
                .filter { !existing.contains($0.identifier) }
                .map {
                    CatalogApp(
                        bundleID: $0.identifier,
                        name: $0.identifier,
                        version: "",
                        type: $0.kind.title,
                        path: $0.path,
                        source: .direct
                    )
                }
            guard !additions.isEmpty else { return }
            apps.append(contentsOf: additions)
            apps.sort { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
            saveCatalogCache()
            Log.info("AppCatalog: +\(additions.count) app từ LaunchServices store (app bị ẩn)", category: .badquery)
        }
    }

    // MARK: - Trực tiếp

    private func reloadDirect() async {
        let report = DirectEngine.shared.capabilityReport()
        if await loadDirectFast(report: report) {
            scheduleIconRefresh()
        }
    }

    /// Liệt kê nhanh nhất có thể; trả về true khi có danh sách.
    @discardableResult
    private func loadDirectFast(report: DirectEngine.CapabilityReport) async -> Bool {
        state = .loading
        do {
            let records = try await Task.detached {
                try DirectEngine.shared.fetchApplicationsFast(limit: 600)
            }.value
            apps = records.map {
                CatalogApp(
                    bundleID: $0.identifier,
                    name: $0.identifier,
                    version: "",
                    type: $0.kind.title,
                    path: nil,
                    source: .direct
                )
            }.sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
            state = .loaded
            saveCatalogCache()
            loadCachedIcons()
            scheduleLaunchServicesMerge()
            if !report.mhaIdentity {
                Log.info("AppCatalog: daemon chấp nhận build (identity chưa phải MHA) — MHA-C2 vẫn hoạt động", category: .badquery)
            }
            return true
        } catch {
            let enumerateError = error

            // iOS 26+ có thể ẩn app khỏi enumerate: thử LaunchServices store
            // (class 10 com.apple.lsd → xác nhận class-2). Soft-gate.
            if report.mcmAvailable {
                let lsRecords = try? await Task.detached { () -> [ContainerRecord] in
                    try DirectEngine.shared.fetchApplicationsViaLaunchServices(limit: 600)
                }.value
                if let lsRecords, !lsRecords.isEmpty {
                    apps = lsRecords.map {
                        CatalogApp(
                            bundleID: $0.identifier,
                            name: $0.identifier,
                            version: "",
                            type: $0.kind.title,
                            path: $0.path,
                            source: .direct
                        )
                    }
                    state = .loaded
                    saveCatalogCache()
                    loadCachedIcons()
                    Log.info("AppCatalog: liệt kê qua LaunchServices store — \(lsRecords.count) app", category: .badquery)
                    return true
                }
            }

            // Fallback cho build không có identity MHA nhưng có App Group:
            // worse_query (class-7) + fsgetpath + MCMMetadataIdentifier.
            if report.mcmAvailable, !report.mhaIdentity, !report.appGroups.isEmpty {
                let records = try? await Task.detached { () -> [ContainerRecord] in
                    try DirectEngine.shared.fetchApplicationsViaEscapeMap(limit: 400) { scanned in
                        if scanned % 25 == 0 {
                            Log.info("AppCatalog: quét container \(scanned)…", category: .badquery)
                        }
                    }
                }.value
                if let records, !records.isEmpty {
                    apps = records.map {
                        CatalogApp(
                            bundleID: $0.identifier,
                            name: $0.identifier,
                            version: "",
                            type: $0.kind.title,
                            path: $0.path,
                            source: .direct
                        )
                    }
                    state = .loaded
                    saveCatalogCache()
                    loadCachedIcons()
                    Log.info("AppCatalog: liệt kê qua worse_query map — \(records.count) app", category: .badquery)
                    return true
                }
            }

            state = .failed(directFailureMessage(report: report, error: enumerateError))
            return false
        }
    }

    private func directFailureMessage(report: DirectEngine.CapabilityReport, error: Error) -> String {
        if !report.mcmAvailable {
            return "MCM không khả dụng: \(error.localizedDescription)"
        }
        if !report.mhaIdentity {
            return "Daemon từ chối vì app không mang identity MHA (cần CẢ CFBundleIdentifier và CodeDirectory identifier = com.apple.mobile.MobileHouseArrest): \(error.localizedDescription). Engine tự dùng worse_query/bad_query/class-2 — xem “Kiểm tra tương thích”."
        }
        return error.localizedDescription
    }

    // MARK: - AirLift

    private func reloadAirlift() async {
        guard AirliftEngine.shared.hasPairing else {
            state = .failed("AirLift cần pairing — mở Settings ▸ Pairing để pair thiết bị trước.")
            return
        }
        guard TunnelManager.shared.isConnected else {
            state = .failed("Cần bật tunnel loopback (VPN) trước — mở Settings ▸ VPN và kết nối.")
            return
        }
        state = .loading
        do {
            let catalog = try await AirliftServices.shared.fetchAppCatalog(iconLimit: 80)
            apps = catalog.apps.map {
                CatalogApp(
                    bundleID: $0.bundleID,
                    name: $0.name,
                    version: $0.version,
                    type: $0.type,
                    path: $0.path,
                    source: .airlift
                )
            }
            state = .loaded
            saveCatalogCache()
            loadCachedIcons()
            applyIcons(catalog.icons)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Icon cache

    private func applyIcons(_ fetched: [String: Data]) {
        for (bundleID, data) in fetched {
            guard let image = UIImage(data: data) else { continue }
            icons[bundleID] = image
            try? data.write(to: iconDirectory.appendingPathComponent("\(bundleID).png"), options: .atomic)
        }
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
