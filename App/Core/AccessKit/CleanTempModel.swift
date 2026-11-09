import Combine
import Foundation

/// Điều phối quét/dọn Temp-Cache (streaming kết quả, có huỷ).
@MainActor
final class CleanTempModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reports: [AppTempReport] = []

    private var scanTask: Task<Void, Never>?

    func report(forBundleID bundleID: String) -> AppTempReport? {
        reports.first { $0.record.identifier == bundleID }
    }

    func scan(records: [ContainerRecord]) {
        scanTask?.cancel()
        reports = []
        guard !records.isEmpty else {
            phase = .ready
            return
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            let total = records.count
            var failures = 0
            for (index, record) in records.enumerated() {
                if Task.isCancelled { return }
                self.phase = .scanning(done: index, total: total)
                do {
                    let report = try await Task.detached {
                        try CleanTempEngine.shared.scan(record)
                    }.value
                    if Task.isCancelled { return }
                    self.reports.append(report)
                    self.reports.sort { $0.totalSize > $1.totalSize }
                } catch {
                    failures += 1
                    continue
                }
            }
            self.phase = .ready
            Log.info("CleanTemp: đã quét \(self.reports.count)/\(total) ứng dụng (lỗi: \(failures))", category: .cleanTemp)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .ready
    }

    /// Deletes `entries` (or all tmp+cache entries) of one app, then rescans it.
    @discardableResult
    func clean(bundleID: String, entries: [TempEntry]?) async -> (deleted: Int, failed: Int) {
        guard let report = report(forBundleID: bundleID) else { return (0, 0) }
        let targets = entries ?? (report.tmpEntries + report.cacheEntries)
        guard !targets.isEmpty else { return (0, 0) }

        let result = await Task.detached {
            CleanTempEngine.shared.delete(targets)
        }.value

        let refreshed = try? await Task.detached {
            try CleanTempEngine.shared.scan(report.record)
        }.value
        if let refreshed {
            reports.removeAll { $0.record.identifier == bundleID }
            reports.append(refreshed)
            reports.sort { $0.totalSize > $1.totalSize }
        }
        Log.info("CleanTemp: \(bundleID) — đã xoá \(result.deleted), lỗi \(result.failed)", category: .cleanTemp)
        return (result.deleted, result.failed)
    }

    /// Cleans every scanned app. Returns aggregate (deleted, failed).
    @discardableResult
    func cleanAll() async -> (deleted: Int, failed: Int) {
        var deleted = 0
        var failed = 0
        for report in reports {
            let result = await clean(bundleID: report.record.identifier, entries: nil)
            deleted += result.deleted
            failed += result.failed
        }
        return (deleted, failed)
    }
}
