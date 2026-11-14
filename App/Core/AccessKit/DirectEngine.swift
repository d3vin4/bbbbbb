import Foundation

/// Container của một ứng dụng hoặc app group.
struct ContainerRecord: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case application
        case appGroup

        var title: String {
            switch self {
            case .application: return "Application"
            case .appGroup: return "App Group"
            }
        }
    }

    let identifier: String
    let kind: Kind
    let path: String

    var id: String { "\(kind.rawValue):\(identifier)" }
}

/// Engine truy cập container — **chỉ dùng worse_query** (class-7 app-group
/// part-directory symlink) + **fsgetpath** để liệt kê thư mục.
///
/// Không cần identity MHA, không cần pairing, không cần tunnel: chỉ cần một
/// App Group entitlement trong profile ký.
final class DirectEngine {
    static let shared = DirectEngine()

    private init() {}

    struct CapabilityReport {
        var hasAppGroup: Bool
        var route: String
    }

    func capabilityReport() -> CapabilityReport {
        CapabilityReport(
            hasAppGroup: !BQCore.appGroupIdentifiers().isEmpty,
            route: BQCore.routeDescription()
        )
    }

    // MARK: - Liệt kê

    /// Liệt kê ứng dụng: dò inode (fsgetpath) trong thư mục container dữ liệu
    /// rồi xin token worse_query cho từng container để đọc định danh (xattr).
    func fetchApplicationsDeep(
        limit: Int = 600,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [ContainerRecord] {
        let candidates = containerCandidates(
            in: "/var/mobile/Containers/Data/Application",
            maxInode: 12_000_000
        )
        var records: [ContainerRecord] = []
        var scanned = 0

        for path in candidates {
            if records.count >= limit { break }
            scanned += 1
            progress?(scanned, candidates.count)

            if let identifier = containerIdentifier(at: path) {
                records.append(ContainerRecord(identifier: identifier, kind: .application, path: path))
                continue
            }
            guard BQCore.grant(forPath: path) >= 0 else { continue }
            if let identifier = containerIdentifier(at: path) {
                records.append(ContainerRecord(identifier: identifier, kind: .application, path: path))
            }
        }

        guard !records.isEmpty else {
            throw Self.error(from: "liệt kê ứng dụng (worse_query)")
        }
        return records.sorted {
            $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
        }
    }

    /// Liệt kê App Group trên máy (cùng cơ chế).
    func fetchAppGroups(limit: Int = 600) throws -> [ContainerRecord] {
        let candidates = containerCandidates(
            in: "/var/mobile/Containers/Shared/AppGroup",
            maxInode: 12_000_000
        )
        var records: [ContainerRecord] = []

        for path in candidates {
            if records.count >= limit { break }
            if let identifier = containerIdentifier(at: path) {
                records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: path))
                continue
            }
            guard BQCore.grant(forPath: path) >= 0 else { continue }
            if let identifier = containerIdentifier(at: path) {
                records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: path))
            }
        }

        guard !records.isEmpty else {
            throw Self.error(from: "liệt kê App Group (worse_query)")
        }
        return records.sorted {
            $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
        }
    }

    /// Tên các gói hệ thống không có container (ví dụ app trong /System/Applications):
    /// chỉ đường dẫn lấy được bằng fsgetpath — không cần token.
    func fetchBundleOnlyNames(limit: Int = 200) -> [(name: String, path: String)] {
        var results: [(name: String, path: String)] = []
        var seen = Set<String>()

        for directory in [
            "/var/staged_system_apps",
            "/System/Applications",
            "/Applications",
        ] {
            for path in BQCore.listDirectoryEntries(directory, maxInode: 12_000_000) {
                guard results.count < limit else { return results }
                guard path.hasSuffix(".app") else { continue }
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                guard !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                results.append((name, path))
            }
        }
        return results
    }

    // MARK: - Truy cập

    /// Mở container: xin token worse_query (token được giữ để đọc cây thư mục).
    @discardableResult
    func activate(_ record: ContainerRecord) throws -> String {
        var target = record.path
        if target.isEmpty {
            target = resolveContainerPath(identifier: record.identifier, kind: record.kind) ?? ""
        }
        guard !target.isEmpty else {
            throw Self.error(from: "kích hoạt \(record.identifier)")
        }
        let handle = BQCore.grant(forPath: target)
        guard handle >= 0 else {
            throw Self.error(from: "worse_query \(record.identifier)")
        }
        return BQCore.resolvedPath(forHandle: handle) ?? target
    }

    /// Bảo đảm có quyền đọc một file (token cho chính file đó).
    @discardableResult
    func ensureFileAccess(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if BQCore.grant(forPath: path) >= 0 { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return BQCore.grant(forPath: parent) >= 0
    }

    /// Liệt kê thư mục: thử `readdir` trước, không được thì dò inode.
    func listDirectory(at path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            return entries
        }
        return BQCore.listDirectoryEntries(path, maxInode: 2_000_000)
    }

    /// Liệt kê không ném lỗi (dùng cho UI và fallback).
    func listDirectorySafe(_ path: String) -> [String] {
        ensureFileAccess(path)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path), !entries.isEmpty {
            return entries
        }
        return BQCore.listDirectoryEntries(path, maxInode: 2_000_000)
            .map { ($0 as NSString).lastPathComponent }
    }

    /// App Group của một ứng dụng: khớp bundle id trong identifier của group
    /// (dạng phổ biến `group.<bundle-id>` hoặc `group.<team>.<app>…`).
    func appGroups(forBundleID bundleID: String) -> [ContainerRecord] {
        guard !bundleID.isEmpty else { return [] }
        let short = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let groups = (try? fetchAppGroups(limit: 900)) ?? []
        return groups.filter {
            $0.identifier.contains(bundleID)
                || $0.identifier.lowercased().contains(short.lowercased())
        }
    }

    /// Đường dẫn container của một bundle id (khi danh sách chưa có path).
    func resolveContainerPath(identifier: String, kind: ContainerRecord.Kind) -> String? {
        guard !identifier.isEmpty else { return nil }
        let directory = kind == .appGroup
            ? "/var/mobile/Containers/Shared/AppGroup"
            : "/var/mobile/Containers/Data/Application"

        for path in containerCandidates(in: directory, maxInode: 12_000_000) {
            if let found = containerIdentifier(at: path), found == identifier {
                return path
            }
            guard BQCore.grant(forPath: path) >= 0 else { continue }
            if let found = containerIdentifier(at: path), found == identifier {
                return path
            }
        }
        return nil
    }

    func releaseLeases() {
        BQCore.releaseAll()
    }

    // MARK: - Nội bộ

    /// Thẻ con của thư mục: xin token cho thư mục cha để đọc thẳng danh sách
    /// (nhanh), nếu không được thì dò inode toàn volume.
    private func containerCandidates(in directory: String, maxInode: UInt64) -> [String] {
        if BQCore.grant(forPath: directory) >= 0 {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory),
               !entries.isEmpty {
                let paths = entries
                    .filter { !$0.hasPrefix(".") }
                    .map { (directory as NSString).appendingPathComponent($0) }
                Log.info(
                    "Direct: token thư mục cha → \(paths.count) mục trong \(directory)",
                    category: .worseQuery
                )
                return paths
            }
        }

        var scannedUpTo: UInt64 = 1
        let scanned = BQCore.listDirectoryEntries(
            directory,
            fromInode: 1,
            maxInode: maxInode,
            scannedUpTo: &scannedUpTo
        )
        Log.info(
            "Direct: fsgetpath → \(scanned.count) mục trong \(directory) (inode 1…\(scannedUpTo))",
            category: .worseQuery
        )
        return scanned
    }

    /// Định danh container (xattr, sau đó mới tới metadata plist).
    private func containerIdentifier(at path: String) -> String? {
        BQCore.containerIdentifier(atPath: path)
    }

    private static func error(from context: String) -> NSError {
        NSError(
            domain: "WorseQueryError",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: BQCore.lastErrorDescription() ?? "\(context) thất bại"]
        )
    }
}
