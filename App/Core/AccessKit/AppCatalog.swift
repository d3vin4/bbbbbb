import Combine
import Foundation
import UIKit

/// App đã cài, hợp nhất từ hai engine (AirLift / Trực tiếp).
struct CatalogApp: Identifiable, Hashable {
    enum Source: String, Hashable {
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

/// Nguồn dữ liệu cho tab Apps: danh sách ứng dụng + icon (cache trên đĩa).
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

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        iconDirectory = caches.appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        loadCachedIcons()
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
        case .airlift:
            await reloadAirlift()
        case .direct:
            await reloadDirect()
        }
    }

    func uninstall(_ app: CatalogApp) async throws {
        guard app.source == .airlift else {
            throw AirliftServicesError.failed("Gỡ cài đặt cần cơ chế AirLift.")
        }
        try await AirliftServices.shared.uninstall(bundleID: app.bundleID)
        apps.removeAll { $0.bundleID == app.bundleID }
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
            let infos = try await AirliftServices.shared.browseApplications()
            apps = infos.map {
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
            loadCachedIcons()
            let missing = apps.map(\.bundleID).filter { icons[$0] == nil }
            guard !missing.isEmpty else { return }
            let batch = Array(missing.prefix(80))
            let fetched = await AirliftServices.shared.fetchIcons(bundleIDs: batch)
            applyIcons(fetched)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Trực tiếp

    private func reloadDirect() async {
        state = .loading
        let report = DirectEngine.shared.capabilityReport()
        guard report.isMHAReady else {
            state = .failed("Trực tiếp cần bundle id MHA-C2 và ký đủ quyền (MCM: \(report.mcmAvailable ? "có" : "thiếu"), identity: \(report.mhaIdentity ? "đúng" : "chưa đúng")).")
            return
        }
        do {
            let records = try await Task.detached {
                try DirectEngine.shared.fetchApplications(limit: 600)
            }.value
            apps = records.map {
                CatalogApp(
                    bundleID: $0.identifier,
                    name: $0.identifier,
                    version: "",
                    type: $0.kind.title,
                    path: $0.path,
                    source: .direct
                )
            }.sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
            state = .loaded
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
}
