import Foundation

/// A container (app data or App Group) discovered on the device.
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

        var mcmClass: UInt64 {
            switch self {
            case .application: return 2
            case .appGroup: return 7
            }
        }
    }

    let identifier: String
    let kind: Kind
    let path: String

    var id: String { "\(kind.rawValue):\(identifier)" }
}

/// Direct container access engine (MHA-C2 + fallback strategies) backed by
/// BadQueryCore (Objective-C).
final class DirectEngine {
    static let shared = DirectEngine()

    private init() {}

    struct CapabilityReport {
        var mcmAvailable: Bool
        var mhaIdentity: Bool
        var appGroups: [String]
        var route: String

        var isMHAReady: Bool { mcmAvailable && mhaIdentity }
    }

    func capabilityReport() -> CapabilityReport {
        CapabilityReport(
            mcmAvailable: BQCore.isAvailable(),
            mhaIdentity: BQCore.hasMHAIdentity(),
            appGroups: BQCore.appGroupIdentifiers(),
            route: BQCore.preferredRouteDescription()
        )
    }

    /// Fast list for UI: identifiers only (one MCM enumerate call, tens of ms).
    /// Container paths and leases resolve lazily when a container is opened.
    func fetchApplicationsFast(limit: Int = 600) throws -> [ContainerRecord] {
        let identifiers = BQCore.enumerateIdentifiers(
            forClass: ContainerRecord.Kind.application.mcmClass,
            limit: UInt(limit)
        )
        guard !identifiers.isEmpty else {
            throw Self.error(from: "liệt kê ứng dụng nhanh")
        }
        return identifiers.map {
            ContainerRecord(identifier: $0, kind: .application, path: "")
        }
    }

    /// Liệt kê app bằng worse_query (class-7) + fsgetpath + đọc
    /// MCMMetadataIdentifier — dùng khi daemon từ chối enumerate (build không
    /// có identity MHA nhưng có App Group entitlement). Chậm hơn một lệnh MCM
    /// nhưng là đường thật, không phải placeholder.
    func fetchApplicationsViaEscapeMap(limit: Int = 400, progress: ((Int) -> Void)? = nil) throws -> [ContainerRecord] {
        let applicationDirectory = "/var/mobile/Containers/Data/Application"
        let candidates = BQCore.listDirectoryEntries(applicationDirectory, maxInode: 1_500_000)
        var records: [ContainerRecord] = []
        var scanned = 0

        for path in candidates {
            if records.count >= limit { break }
            scanned += 1
            progress?(scanned)

            let handle = BQCore.escapeTarget(path)
            guard handle >= 0 else { continue }
            defer { BQCore.endEscape(handle) }

            let metadataPath = (path as NSString)
                .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
                  let plistObject = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let plist = plistObject as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String,
                  !identifier.isEmpty else {
                continue
            }
            records.append(ContainerRecord(identifier: identifier, kind: .application, path: path))
        }

        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    /// iOS 26+ có thể ẩn app khỏi ContainerManager/LaunchServices enumeration.
    /// Đọc store LaunchServices qua container class-10 của `com.apple.lsd`
    /// (kỹ thuật FilzaSlop), trích candidate bundle id rồi xác nhận từng cái
    /// bằng class-2 lookup. Soft-gate: daemon quyết định.
    func fetchApplicationsViaLaunchServices(limit: Int = 600) throws -> [ContainerRecord] {
        guard let container = BQCore.activateContainer(forClass: 10, identifier: "com.apple.lsd", group: false) else {
            throw Self.error(from: "kích hoạt com.apple.lsd (class 10)")
        }

        let cachesPath = (container as NSString).appendingPathComponent("Library/Caches")
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: cachesPath) else {
            throw Self.error(from: "đọc Library/Caches của lsd")
        }

        let storeNames = names.filter {
            $0.hasPrefix("com.apple.LaunchServices-") && $0.hasSuffix("-v2.csstore")
        }
        guard !storeNames.isEmpty else {
            throw Self.error(from: "không thấy LaunchServices store")
        }

        var candidates = Set<String>()
        for name in storeNames {
            let path = (cachesPath as NSString).appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? UInt64,
                  size > 0, size < 256 * 1024 * 1024 else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { continue }
            candidates.formUnion(Self.bundleIdentifierCandidates(in: data))
            if candidates.count > 65_536 { break }
        }

        var records: [ContainerRecord] = []
        for candidate in candidates {
            if records.count >= limit { break }
            if let path = try? BQCore.containerPath(forClass: 2, identifier: candidate, group: false) {
                records.append(ContainerRecord(identifier: candidate, kind: .application, path: path))
            }
        }
        guard !records.isEmpty else {
            throw Self.error(from: "xác nhận LaunchServices candidates")
        }
        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    /// Trích các candidate bundle-id từ store nhị phân (csstore).
    private static func bundleIdentifierCandidates(in data: Data) -> Set<String> {
        var candidates = Set<String>()
        var current = [UInt8]()
        current.reserveCapacity(64)

        for byte in data {
            let allowed = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
            if allowed {
                current.append(byte)
                if current.count > 128 {
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            if current.count >= 8, let string = String(bytes: current, encoding: .utf8) {
                let dotCount = string.reduce(0) { $0 + ($1 == "." ? 1 : 0) }
                if dotCount >= 2,
                   !string.hasPrefix("."), !string.hasSuffix("."),
                   string.first?.isLetter == true {
                    candidates.insert(string)
                    if candidates.count > 65_536 { return candidates }
                }
            }
            current.removeAll(keepingCapacity: true)
        }
        return candidates
    }

    /// Installed apps: bundle identifier + data container path.
    func fetchApplications(limit: Int = 600) throws -> [ContainerRecord] {
        let identifiers = BQCore.enumerateIdentifiers(
            forClass: ContainerRecord.Kind.application.mcmClass,
            limit: UInt(limit)
        )
        guard !identifiers.isEmpty else {
            throw Self.error(from: "liệt kê ứng dụng")
        }

        var records: [ContainerRecord] = []
        records.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            let containerPath: String? = BQCore.containerPath(
                forClass: ContainerRecord.Kind.application.mcmClass,
                identifier: identifier,
                group: false
            )
            if let containerPath {
                records.append(ContainerRecord(identifier: identifier, kind: .application, path: containerPath))
            }
        }
        return records
    }

    /// App Group containers: group identifier + container path.
    func fetchAppGroups(limit: Int = 600) throws -> [ContainerRecord] {
        do {
            let identifiers = BQCore.enumerateIdentifiers(
                forClass: ContainerRecord.Kind.appGroup.mcmClass,
                limit: UInt(limit)
            )
            guard !identifiers.isEmpty else {
                throw Self.error(from: "liệt kê App Group")
            }

            var records: [ContainerRecord] = []
            records.reserveCapacity(identifiers.count)
            for identifier in identifiers {
                let containerPath: String? = BQCore.containerPath(
                    forClass: ContainerRecord.Kind.appGroup.mcmClass,
                    identifier: identifier,
                    group: true
                )
                if let containerPath {
                    records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: containerPath))
                }
            }
            if !records.isEmpty {
                return records
            }
        } catch {
            Log.warning("Direct: enumerate App Group lỗi — thử escape-map (\(error.localizedDescription))", category: .badquery)
        }
        return try fetchAppGroupsViaEscapeMap(limit: limit)
    }

    /// Fallback: liệt kê App Group qua fsgetpath + metadata (không cần enumerate).
    func fetchAppGroupsViaEscapeMap(limit: Int = 600) throws -> [ContainerRecord] {
        let groupDirectory = "/var/mobile/Containers/Shared/AppGroup"
        let candidates = BQCore.listDirectoryEntries(groupDirectory, maxInode: 1_500_000)
        var records: [ContainerRecord] = []
        for path in candidates {
            if records.count >= limit { break }
            let handle = BQCore.escapeTarget(path)
            guard handle >= 0 else { continue }
            defer { BQCore.endEscape(handle) }

            let metadataPath = (path as NSString)
                .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
                  let plistObject = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let plist = plistObject as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String,
                  !identifier.isEmpty else {
                continue
            }
            records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: path))
        }
        guard !records.isEmpty else {
            throw Self.error(from: "liệt kê App Group (escape-map)")
        }
        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    private let cacheLock = NSLock()
    private var activatedPaths: [String: String] = [:]

    /// Activates a container and returns its usable path — nhanh nhất có thể:
    /// 1) cache trong phiên (mở lại tức thì), 2) MHA-C2 lease (1 lệnh MCM),
    /// 3) fallback worse_query class-7 / bad_query / class-2 (không cần bundle MHA).
    @discardableResult
    func activate(_ record: ContainerRecord) throws -> String {
        if let cached = cachedPath(for: record.id) {
            return cached
        }

        if let leased = BQCore.activateContainer(
            forClass: record.kind.mcmClass,
            identifier: record.identifier,
            group: record.kind == .appGroup
        ) {
            store(cachedPath: leased, for: record.id)
            return leased
        }

        // Fallback: escape strategies (worse_query class-7 ưu tiên).
        var target = record.path
        if target.isEmpty {
            target = (try? BQCore.containerPath(
                forClass: record.kind.mcmClass,
                identifier: record.identifier,
                group: record.kind == .appGroup
            )) ?? ""
        }
        guard !target.isEmpty else {
            throw Self.error(from: "kích hoạt \(record.identifier)")
        }

        let handle = BQCore.escapeTarget(target)
        guard handle >= 0 else {
            throw Self.error(from: "escape \(record.identifier)")
        }
        let escaped = BQCore.escapedPath(forHandle: handle) ?? target
        store(cachedPath: escaped, for: record.id)
        return escaped
    }

    private func cachedPath(for key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return activatedPaths[key]
    }

    private func store(cachedPath path: String, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        activatedPaths[key] = path
    }

    /// Directory listing that falls back to fsgetpath enumeration when readdir
    /// is denied inside the container.
    func listDirectory(at path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            return entries.map(\.lastPathComponent)
        }
        let enumerated = BQCore.listDirectoryEntries(path, maxInode: 2_000_000)
        return enumerated.map { ($0 as NSString).lastPathComponent }
    }

    func releaseLeases() {
        BQCore.releaseLeases()
    }

    private static func error(from context: String) -> NSError {
        NSError(
            domain: "BQCoreErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: BQCore.lastErrorDescription() ?? "\(context) thất bại"]
        )
    }
}
