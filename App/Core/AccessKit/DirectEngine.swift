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

    /// Liệt kê ứng dụng qua worse_query (class-7) — không cần identity MHA.
    ///
    /// Cách làm: escape thư mục cha để đọc được danh sách container, rồi escape
    /// từng container để đọc `MCMMetadataIdentifier` (bundle id). Token của thư
    /// mục cha KHÔNG bao hàm quyền đọc cây con, nên mỗi container vẫn cần token
    /// riêng — đây là đường duy nhất liệt kê được app của máy khác khi app
    /// không mang identity MHA.
    func fetchApplicationsDeep(limit: Int = 600, progress: ((Int, Int) -> Void)? = nil) throws -> [ContainerRecord] {
        // Chỉ container dữ liệu app (extension nằm ở root khác, liệt kê riêng
        // để không làm loãng danh sách ứng dụng).
        var records: [ContainerRecord] = []
        var scanned = 0
        var total = 0

        for directory in [
            "/var/mobile/Containers/Data/Application",
        ] {
            // Trần inode cao hơn (12M) để không bỏ sót container có inode lớn.
            let candidates = containerCandidates(in: directory, maxInode: 12_000_000)
            total += candidates.count

            for path in candidates {
                if records.count >= limit { break }
                scanned += 1
                progress?(scanned, total)

                // Database iOS đã biết bundle id của container này → khỏi escape
                // (nhanh gấp bội: không swap + query cho từng container).
                if let known = LaunchServicesIndex.shared.identifier(forContainer: path) {
                    records.append(ContainerRecord(identifier: known, kind: .application, path: path))
                    continue
                }

                // Container của chính app luôn đọc được → không cần escape.
                if let identifier = Self.containerIdentifier(at: path) {
                    records.append(ContainerRecord(identifier: identifier, kind: .application, path: path))
                    continue
                }

                // Container của app khác: cần token riêng để đọc metadata.
                let handle = BQCore.escapeTarget(path)
                guard handle >= 0 else { continue }
                let escaped = BQCore.escapedPath(forHandle: handle) ?? path
                let identifier = Self.containerIdentifier(at: escaped) ?? Self.containerIdentifier(at: path)
                BQCore.endEscape(handle)
                guard let identifier else { continue }
                records.append(ContainerRecord(identifier: identifier, kind: .application, path: path))
            }
        }

        guard !records.isEmpty else {
            throw Self.error(from: "liệt kê ứng dụng (worse_query)")
        }
        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    /// Quét gói ứng dụng: bundle luôn tồn tại kể cả khi app chưa có container
    /// dữ liệu — đọc Info.plist để lấy bundle id + tên hiển thị. Đây là nguồn
    /// bổ sung để danh sách ĐỦ app (kèm tên thật) khi database iOS thiếu.
    func fetchApplicationsFromBundles(
        limit: Int = 600,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [(bundleID: String, name: String, icon: Data?)] {
        let directory = "/var/containers/Bundle/Application"
        let candidates = containerCandidates(in: directory)
        var results: [(bundleID: String, name: String, icon: Data?)] = []
        var scanned = 0
        var dirTokens = 0
        var fileTokens = 0
        var plistReads = 0

        for candidate in candidates {
            if results.count >= limit { break }
            scanned += 1
            progress?(scanned, candidates.count)

            // Token cho thư mục bundle (UUID) rồi tìm file .app bên trong.
            let dirHandle = BQCore.escapeTarget(candidate)
            if dirHandle >= 0 { dirTokens += 1 }
            guard dirHandle >= 0 else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: candidate)) ?? []
            guard let appName = entries.first(where: { $0.hasSuffix(".app") }) else { continue }

            let appPath = (candidate as NSString).appendingPathComponent(appName)
            let infoPath = (appPath as NSString).appendingPathComponent("Info.plist")
            // Token thư mục bundle thường đã phủ Info.plist — chỉ xin thêm token
            // cho chính file khi lần đọc đầu bị từ chối.
            var infoData = try? Data(contentsOf: URL(fileURLWithPath: infoPath))
            if infoData == nil {
                if BQCore.escapeTarget(infoPath) >= 0 { fileTokens += 1 }
                infoData = try? Data(contentsOf: URL(fileURLWithPath: infoPath))
            }
            if infoData == nil {
                // Chốt cuối: token cho cả gói .app rồi đọc lại.
                if BQCore.escapeTarget(appPath) >= 0 { fileTokens += 1 }
                infoData = try? Data(contentsOf: URL(fileURLWithPath: infoPath))
            }
            if infoData != nil { plistReads += 1 }
            guard let data = infoData,
                  let plistObject = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let plist = plistObject as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? bundleID

            // Icon đọc ngay trong lúc còn token của gói (không cần Airlift).
            let icon = AppIconExtractor.bundleIcon(appPath: appPath, info: plist)
            results.append((bundleID, name, icon))
        }

        Log.info(
            "Direct: bundle scan — \(candidates.count) gói, dir token \(dirTokens), file token \(fileTokens), đọc Info.plist \(plistReads)",
            category: .badquery
        )
        guard !results.isEmpty else {
            throw Self.error(from: "quét gói ứng dụng")
        }
        return results
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

        return resolvePaths(identifiers: identifiers, kind: .application, group: false)
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

            let records = resolvePaths(identifiers: identifiers, kind: .appGroup, group: true)
            if !records.isEmpty {
                return records
            }
        } catch {
            Log.warning("Direct: enumerate App Group lỗi — thử escape-map (\(error.localizedDescription))", category: .badquery)
        }
        return try fetchAppGroupsViaEscapeMap(limit: limit)
    }

    /// Liệt kê App Group qua worse_query (class-7) — không cần enumerate.
    func fetchAppGroupsViaEscapeMap(limit: Int = 600) throws -> [ContainerRecord] {
        let groupDirectory = "/var/mobile/Containers/Shared/AppGroup"
        let candidates = containerCandidates(in: groupDirectory)
        var records: [ContainerRecord] = []

        for path in candidates {
            if records.count >= limit { break }

            if let identifier = Self.containerIdentifier(at: path) {
                records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: path))
                continue
            }

            let handle = BQCore.escapeTarget(path)
            guard handle >= 0 else { continue }
            let escaped = BQCore.escapedPath(forHandle: handle) ?? path
            let identifier = Self.containerIdentifier(at: escaped) ?? Self.containerIdentifier(at: path)
            BQCore.endEscape(handle)
            guard let identifier else { continue }
            records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: path))
        }
        guard !records.isEmpty else {
            throw Self.error(from: "liệt kê App Group (worse_query)")
        }
        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    // MARK: - Path resolution (song song khi có MHA)

    /// Resolve container paths cho danh sách identifier. Khi có MHA-C2, các
    /// truy vấn độc lập chạy song song (nhanh hơn nhiều với vài trăm app).
    private func resolvePaths(identifiers: [String], kind: ContainerRecord.Kind, group: Bool) -> [ContainerRecord] {
        guard !identifiers.isEmpty else { return [] }

        if BQCore.isAvailable() && BQCore.hasMHAIdentity() {
            var records: [ContainerRecord] = []
            let lock = NSLock()
            let queue = DispatchQueue(label: "com.d3vin4.bbbbbb.mcm.resolve", attributes: .concurrent)
            let dispatchGroup = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 6)

            for identifier in identifiers {
                dispatchGroup.enter()
                queue.async {
                    semaphore.wait()
                    defer {
                        semaphore.signal()
                        dispatchGroup.leave()
                    }
                    if let path = try? BQCore.containerPath(
                        forClass: kind.mcmClass,
                        identifier: identifier,
                        group: group
                    ) {
                        lock.lock()
                        records.append(ContainerRecord(identifier: identifier, kind: kind, path: path))
                        lock.unlock()
                    }
                }
            }
            dispatchGroup.wait()
            return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
        }

        var records: [ContainerRecord] = []
        records.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            if let path = try? BQCore.containerPath(
                forClass: kind.mcmClass,
                identifier: identifier,
                group: group
            ) {
                records.append(ContainerRecord(identifier: identifier, kind: kind, path: path))
            }
        }
        return records.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    // MARK: - Quét container (worse_query)

    /// Liệt kê các thư mục con của thư mục chứa container.
    ///
    /// Ưu tiên escape thư mục cha (class-7) rồi đọc thư mục — nhanh và đủ.
    /// Nếu không được thì quét fsgetpath (chậm hơn nhiều).
    private func containerCandidates(in directory: String, maxInode: UInt64 = 6_000_000) -> [String] {
        let handle = BQCore.escapeTarget(directory)
        if handle >= 0 {
            defer { BQCore.endEscape(handle) }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            let paths = entries
                .filter { !$0.hasPrefix(".") }
                .map { (directory as NSString).appendingPathComponent($0) }
            if !paths.isEmpty {
                Log.info("Direct: parent escape → \(paths.count) container trong \(directory)", category: .badquery)
                return paths
            }
        }

        Log.info("Direct: parent escape không được token (đúng như 27.0) — quét fsgetpath", category: .badquery)
        // Luôn quét toàn dải inode: mốc tăng dần trước đây khiến lần quét sau
        // bắt đầu ở cuối dải và KHÔNG thấy container nào (danh sách cũ bị giữ).
        // Chi phí xử lý đã được giảm bằng map database (không escape từng cái).
        var scannedUpTo: UInt64 = 1
        let scanned = BQCore.listDirectoryEntries(
            directory,
            fromInode: 1,
            maxInode: maxInode,
            scannedUpTo: &scannedUpTo
        )
        Log.info(
            "Direct: fsgetpath → \(scanned.count) container trong \(directory) (inode 1…\(scannedUpTo))",
            category: .badquery
        )
        return scanned
    }

    /// Tìm đường dẫn container của một bundle id (dùng khi danh sách chưa có path).
    func resolveContainerPath(identifier: String, kind: ContainerRecord.Kind) -> String? {
        if let path = try? BQCore.containerPath(
            forClass: kind.mcmClass,
            identifier: identifier,
            group: kind == .appGroup
        ), !path.isEmpty {
            return path
        }

        let directory = kind == .appGroup
            ? "/var/mobile/Containers/Shared/AppGroup"
            : "/var/mobile/Containers/Data/Application"

        for path in containerCandidates(in: directory) {
            let handle = BQCore.escapeTarget(path)
            guard handle >= 0 else { continue }
            let escaped = BQCore.escapedPath(forHandle: handle) ?? path
            let found = Self.containerIdentifier(at: escaped) ?? Self.containerIdentifier(at: path)
            BQCore.endEscape(handle)
            if found == identifier { return path }
        }
        return nil
    }

    /// Đọc bundle/group identifier của container: xattr → map containermanager
    /// → metadata plist (làm trong BQCore; metadata plist thường root-only nên
    /// chỉ là chốt cuối).
    private static func containerIdentifier(at path: String) -> String? {
        BQCore.containerIdentifier(atPath: path)
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
        if target.isEmpty {
            // Chưa biết đường dẫn container → tìm bằng cách quét container.
            target = resolveContainerPath(identifier: record.identifier, kind: record.kind) ?? ""
        }
        guard !target.isEmpty else {
            throw Self.error(from: "kích hoạt \(record.identifier)")
        }

        // Token riêng cho container này (class-7) — giữ nguyên để đọc được
        // cây thư mục khi duyệt tệp.
        let handle = BQCore.escapeTarget(target)
        if handle < 0 {
            // Không lấy được token (ví dụ thư mục cha/SystemGroup trên 27.0):
            // vẫn cho duyệt chỉ-đọc qua fsgetpath thay vì báo lỗi truy cập.
            let entries = BQCore.listDirectoryEntries(target, maxInode: 6_000_000)
            if !entries.isEmpty {
                Log.info(
                    "Direct: \(target) không có token — duyệt chỉ-đọc qua fsgetpath",
                    category: .badquery
                )
                store(cachedPath: target, for: record.id)
                return target
            }
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

    // MARK: - App Group của một app

    private static let groupCacheLock = NSLock()
    private static var groupCache: (records: [ContainerRecord], date: Date)?

    /// Toàn bộ App Group trên máy (quét một lần, cache 1 giờ).
    func allAppGroups() -> [ContainerRecord] {
        Self.groupCacheLock.lock()
        if let cached = Self.groupCache, Date().timeIntervalSince(cached.date) < 3600 {
            Self.groupCacheLock.unlock()
            return cached.records
        }
        Self.groupCacheLock.unlock()

        let records = (try? fetchAppGroupsViaEscapeMap(limit: 900)) ?? []

        Self.groupCacheLock.lock()
        Self.groupCache = (records, Date())
        Self.groupCacheLock.unlock()
        return records
    }

    /// App Group của một app: khớp bundle id trong identifier của group
    /// (dạng phổ biến `group.<bundle-id>`, `group.<team>.<app>…`).
    func appGroups(forBundleID bundleID: String) -> [ContainerRecord] {
        guard !bundleID.isEmpty else { return [] }
        let short = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return allAppGroups().filter {
            $0.identifier.contains(bundleID) || $0.identifier.lowercased().contains(short.lowercased())
        }
    }

    /// Tên các app KHÔNG có container (app hệ thống gỡ được) — chỉ lấy ĐƯỜNG
    /// DẪN bằng fsgetpath: kernel trả path theo inode, không cần token nên vẫn
    /// liệt kê được dù daemon chặn đọc nội dung gói.
    func fetchBundleOnlyNames(limit: Int = 200) -> [(name: String, path: String)] {
        var results: [(name: String, path: String)] = []
        var seen = Set<String>()

        // App hệ thống: chúng nằm trong /System/Applications (không có container
        // dữ liệu riêng) và các gói staged — tên lấy qua fsgetpath (không cần
        // token nên vẫn thấy dù daemon chặn đọc nội dung gói).
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

    /// Đường dẫn gói `.app` qua lease class-5 (cơ chế lease, khác symlink nên
    /// có thể qua được chỗ symlink bị chặn) — dùng để đọc Info.plist + icon mà
    /// không cần Airlift.
    func bundlePath(forBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return BQCore.activateContainer(forClass: 5, identifier: bundleID, group: false)
    }

    /// Bảo đảm token truy cập cho một file cụ thể trước khi đọc (token thư mục
    /// đôi khi chỉ phủ liệt kê). Grant cache làm lần sau miễn phí.
    @discardableResult
    func ensureFileAccess(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if BQCore.escapeTarget(path) >= 0 { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return BQCore.escapeTarget(parent) >= 0
    }

    /// Liệt kê không ném lỗi (dùng cho shell/LAN server).
    func listDirectorySafe(_ path: String) -> [String] {
        ensureFileAccess(path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        if !entries.isEmpty { return entries }
        return BQCore.listDirectoryEntries(path, maxInode: 6_000_000)
            .map { ($0 as NSString).lastPathComponent }
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
