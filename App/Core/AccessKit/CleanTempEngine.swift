import Foundation

/// Một mục trong tmp/ hoặc Library/Caches của container ứng dụng.
struct TempEntry: Identifiable, Hashable {
    let path: String
    let size: UInt64
    let isDirectory: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Kết quả quét Temp/Cache của một ứng dụng.
struct AppTempReport: Identifiable, Hashable {
    let record: ContainerRecord
    var tmpEntries: [TempEntry]
    var cacheEntries: [TempEntry]

    var id: String { record.id }
    var tmpSize: UInt64 { tmpEntries.reduce(0) { $0 + $1.size } }
    var cacheSize: UInt64 { cacheEntries.reduce(0) { $0 + $1.size } }
    var totalSize: UInt64 { tmpSize + cacheSize }
}

/// Quét và dọn tmp/Library/Caches của container ứng dụng qua engine Trực tiếp
/// (MHA-C2 lease → POSIX file ops).
final class CleanTempEngine {
    static let shared = CleanTempEngine()

    private init() {}

    /// Scans one app container: `tmp/` (recursive files) and `Library/Caches`
    /// (direct children with recursive sizes).
    func scan(_ record: ContainerRecord) throws -> AppTempReport {
        let container = try DirectEngine.shared.activate(record)
        let tmp = (container as NSString).appendingPathComponent("tmp")
        let caches = (container as NSString).appendingPathComponent("Library/Caches")
        return AppTempReport(
            record: record,
            tmpEntries: Self.fileEntries(in: tmp),
            cacheEntries: Self.childEntries(in: caches)
        )
    }

    /// Deletes the given entries. Returns (deleted, failed) counts.
    func delete(_ entries: [TempEntry]) -> (deleted: Int, failed: Int) {
        var deleted = 0
        var failed = 0
        for entry in entries {
            do {
                try FileManager.default.removeItem(atPath: entry.path)
                deleted += 1
            } catch {
                failed += 1
            }
        }
        return (deleted, failed)
    }

    // MARK: - Scanning helpers

    private static func fileEntries(in directory: String) -> [TempEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: directory) else { return [] }
        var entries: [TempEntry] = []
        var scanned = 0
        for case let relative as String in enumerator {
            scanned += 1
            if scanned > 2000 { break }
            let full = (directory as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            entries.append(TempEntry(path: full, size: fileSize(full), isDirectory: false))
        }
        return entries.sorted { $0.size > $1.size }
    }

    private static func childEntries(in directory: String) -> [TempEntry] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        var entries: [TempEntry] = []
        for name in names {
            let full = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }
            let size = isDirectory.boolValue ? directorySize(full, cap: 3000) : fileSize(full)
            entries.append(TempEntry(path: full, size: size, isDirectory: isDirectory.boolValue))
        }
        return entries.sorted { $0.size > $1.size }
    }

    private static func directorySize(_ path: String, cap: Int) -> UInt64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        var scanned = 0
        for case let relative as String in enumerator {
            scanned += 1
            if scanned > cap { break }
            let full = (path as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            total += fileSize(full)
        }
        return total
    }

    private static func fileSize(_ path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attributes[.size] as? UInt64) ?? 0
    }
}
