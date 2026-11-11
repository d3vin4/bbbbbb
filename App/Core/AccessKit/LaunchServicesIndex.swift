import Foundation

/// Một app/extension trong database của LaunchServices.
struct LaunchServicesEntry: Sendable {
    let bundleID: String
    let name: String
    let containerPath: String?
    let isExtension: Bool
}

/// Đọc danh sách ứng dụng từ database của LaunchServices
/// (`com.apple.LaunchServices-*.csstore` trong container của daemon) — nhanh,
/// có tên, có container path, không cần quét từng container.
///
/// Định dạng store (magic "bdsl"): mỗi record là một cặp
/// `[sid][độ dài][bytes]` cho string, và record app/plugin giữ các `sid` tham
/// chiếu tới string đó. Kích thước record + offset field khác nhau giữa các
/// bản iOS nên thử vài layout rồi chọn layout map được nhiều container nhất.
final class LaunchServicesIndex: @unchecked Sendable {
    static let shared = LaunchServicesIndex()

    struct Layout {
        let label: String
        let bundleSize: UInt32
        let bundleID: UInt32
        let container: UInt32
        let name: UInt32
        let displayName: UInt32
        let pluginSize: UInt32
        let pluginBundleID: UInt32
        let pluginContainer: UInt32
    }

    static let layouts: [Layout] = [
        .init(label: "27.0", bundleSize: 0x250, bundleID: 0x0c, container: 0x68, name: 0x6c, displayName: 0x74,
              pluginSize: 0x118, pluginBundleID: 0x00, pluginContainer: 0x54),
        .init(label: "26", bundleSize: 0x23c, bundleID: 0x0c, container: 0x64, name: 0x68, displayName: 0x70,
              pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x50),
        .init(label: "27.2", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78,
              pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
        .init(label: "27.2b", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c, name: 0x70, displayName: 0x78,
              pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        .init(label: "27.2c", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78,
              pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        .init(label: "27.2d", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c, name: 0x70, displayName: 0x78,
              pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
    ]

    private static let storePathKey = "bbbbbb.lsStorePath"
    private static let maxStringID: UInt32 = 1 << 22
    private static let maxRecords = 40_000

    private let lock = NSLock()
    private var cachedEntries: [LaunchServicesEntry]?
    private var containerMap: [String: String] = [:]
    private let entriesFileURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        entriesFileURL = caches.appendingPathComponent("LaunchServicesIndex.json")
    }

    /// Danh sách app từ database (đọc 1 lần, nhớ trong RAM + đĩa).
    func entries(forceReload: Bool = false) -> [LaunchServicesEntry] {
        lock.lock()
        defer { lock.unlock() }

        if !forceReload, let cachedEntries { return cachedEntries }
        if !forceReload, let disk = loadFromDisk() {
            cachedEntries = disk
            rebuildContainerMap(disk)
            Log.info("LaunchServices: nạp index \(disk.count) mục (đĩa)", category: .app)
            return disk
        }

        guard let storePath = findStore() else {
            Log.info("LaunchServices: chưa tìm thấy database", category: .app)
            return []
        }

        // File nằm trong container của daemon → cần token cho thư mục chứa nó
        // trong suốt quá trình đọc (trước đây thu hồi token rồi mới đọc → lỗi).
        // Token cho cả thư mục chứa lẫn chính file (token thư mục đôi khi chỉ
        // phủ việc liệt kê, không phủ đọc file bên trong).
        let storeDirectory = (storePath as NSString).deletingLastPathComponent
        let dirHandle = BQCore.escapeTarget(storeDirectory)
        defer {
            if dirHandle >= 0 { BQCore.endEscape(dirHandle) }
        }
        let fileHandle = BQCore.escapeTarget(storePath)
        defer {
            if fileHandle >= 0 { BQCore.endEscape(fileHandle) }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath), options: .mappedIfSafe) else {
            Log.warning(
                "LaunchServices: không đọc được \(storePath) (token dir \(dirHandle), file \(fileHandle))",
                category: .app
            )
            return []
        }

        let parsed = Self.parse(data: data)
        if !parsed.isEmpty {
            cachedEntries = parsed
            rebuildContainerMap(parsed)
            saveToDisk(parsed)
        }
        Log.info("LaunchServices: parse \(parsed.count) mục từ \(storePath)", category: .app)
        return parsed
    }

    /// Bundle id của container (theo đường dẫn) — dùng để bỏ hẳn việc escape
    /// từng container khi quét. Tự nạp index nếu chưa có.
    func identifier(forContainer path: String) -> String? {
        _ = entries()
        lock.lock()
        defer { lock.unlock() }
        return containerMap[Self.normalized(path)]
    }

    private func rebuildContainerMap(_ entries: [LaunchServicesEntry]) {
        var map: [String: String] = [:]
        for entry in entries {
            guard let container = entry.containerPath, !container.isEmpty else { continue }
            map[Self.normalized(container)] = entry.bundleID
        }
        containerMap = map
    }

    private static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        return standardized
    }

    /// Xoá index đã lưu (dùng khi muốn dò lại từ đầu).
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedEntries = nil
        try? FileManager.default.removeItem(at: entriesFileURL)
        UserDefaults.standard.removeObject(forKey: Self.storePathKey)
    }

    // MARK: - Tìm store

    private func findStore() -> String? {
        if let saved = UserDefaults.standard.string(forKey: Self.storePathKey),
           FileManager.default.isReadableFile(atPath: saved) {
            return saved
        }

        // Container của daemon: escape từng cái rồi soi Library/Caches.
        let directory = "/var/mobile/Containers/Data/InternalDaemon"
        let containers = BQCore.listDirectoryEntries(directory, maxInode: 6_000_000)
        for container in containers {
            let handle = BQCore.escapeTarget(container)
            guard handle >= 0 else { continue }
            let caches = (container as NSString).appendingPathComponent("Library/Caches")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: caches)) ?? []
            var best: (path: String, date: Date)?
            for name in names where name.hasPrefix("com.apple.LaunchServices-") && name.hasSuffix(".csstore") {
                let path = (caches as NSString).appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let date = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
                if best == nil || date > best!.date {
                    best = (path, date)
                }
            }
            BQCore.endEscape(handle)

            if let best {
                UserDefaults.standard.set(best.path, forKey: Self.storePathKey)
                Log.info("LaunchServices: tìm thấy database tại \(best.path)", category: .app)
                return best.path
            }
        }
        return nil
    }

    // MARK: - Parse

    static func parse(data: Data) -> [LaunchServicesEntry] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [LaunchServicesEntry] in
            let n = raw.count
            guard n > 4096, let base = raw.baseAddress else { return [] }
            let b = base.assumingMemoryBound(to: UInt8.self)
            guard b[0] == 0x62, b[1] == 0x64, b[2] == 0x73, b[3] == 0x6c else { return [] }  // "bdsl"

            func rd32(_ offset: Int) -> UInt32 {
                guard offset >= 0, offset + 4 <= n else { return 0 }
                return UInt32(b[offset])
                    | UInt32(b[offset + 1]) << 8
                    | UInt32(b[offset + 2]) << 16
                    | UInt32(b[offset + 3]) << 24
            }
            func validRef(_ value: UInt32) -> Bool {
                value != 0 && (value & 3) == 0 && (value >> 2) < maxStringID
            }

            let heapOffset = findHeapOffset(b, n)
            let maxRecordSize = Int(layouts.map { max($0.bundleSize, $0.pluginSize) }.max() ?? 0x25c)

            var bundleRecords = [[(id: UInt32, name: UInt32, display: UInt32, container: UInt32)]](repeating: [], count: layouts.count)
            var pluginRecords = [[(id: UInt32, container: UInt32)]](repeating: [], count: layouts.count)
            var needed = Set<UInt32>()

            var offset = 0
            while offset + 8 + maxRecordSize <= n {
                let size = rd32(offset + 4)
                if size != 0 {
                    for (index, layout) in layouts.enumerated() {
                        let body = offset + 8
                        if size == layout.pluginSize {
                            let id = rd32(body + Int(layout.pluginBundleID))
                            let container = rd32(body + Int(layout.pluginContainer))
                            if validRef(id), validRef(container), pluginRecords[index].count < maxRecords {
                                pluginRecords[index].append((id, container))
                                needed.insert(id)
                                needed.insert(container)
                            }
                        }
                        if size == layout.bundleSize {
                            let id = rd32(body + Int(layout.bundleID))
                            let name = rd32(body + Int(layout.name))
                            let display = rd32(body + Int(layout.displayName))
                            let container = rd32(body + Int(layout.container))
                            if validRef(id), bundleRecords[index].count < maxRecords {
                                bundleRecords[index].append((id, name, display, container))
                                needed.insert(id)
                                for reference in [name, display, container] where validRef(reference) {
                                    needed.insert(reference)
                                }
                            }
                        }
                    }
                }
                offset += 4
            }

            guard !needed.isEmpty else { return [] }

            // Pass 2: string table.
            var strings: [UInt32: String] = [:]
            var heapIDs = Set<UInt32>()
            offset = 0
            while offset + 8 <= n {
                let sid = rd32(offset)
                if sid != 0, needed.contains(sid) {
                    let length = Int(rd32(offset + 4))
                    if length > 0, length < 0x800, offset + 8 + length <= n {
                        let inHeap = offset >= heapOffset
                        if strings[sid] == nil || (inHeap && !heapIDs.contains(sid)) {
                            if let value = decodeString(b, offset + 8, length) {
                                strings[sid] = value
                                if inHeap { heapIDs.insert(sid) } else { heapIDs.remove(sid) }
                            }
                        }
                    }
                }
                offset += 4
            }

            // Hint: kích thước record phổ biến nhất — log để bổ sung layout nếu
            // bảng hiện tại không khớp bản iOS này.
            var sizeCounts: [UInt32: Int] = [:]
            var hintOffset = 0
            while hintOffset + 8 <= n {
                let size = rd32(hintOffset + 4)
                if size >= 0x100, size <= 0x800, size % 4 == 0 {
                    sizeCounts[size, default: 0] += 1
                }
                hintOffset += 4
            }
            let hints = sizeCounts.sorted { $0.value > $1.value }
                .prefix(6)
                .map { String(format: "0x%x×%d", $0.key, $0.value) }
                .joined(separator: ", ")
            Log.info("LaunchServices: size hint [\(hints)]", category: .app)

            guard !strings.isEmpty else { return [] }

            // Chọn layout map được nhiều container nhất.
            var best: [LaunchServicesEntry] = []
            var bestMapped = -1
            for index in layouts.indices {
                var entries: [LaunchServicesEntry] = []
                var seen = Set<String>()

                for record in bundleRecords[index] {
                    guard let id = strings[record.id], looksLikeBundleID(id), !seen.contains(id) else { continue }
                    let container = strings[record.container].flatMap { isDataContainer($0) ? $0 : nil }
                    let name = strings[record.display] ?? strings[record.name] ?? id
                    seen.insert(id)
                    entries.append(LaunchServicesEntry(bundleID: id, name: name, containerPath: container, isExtension: false))
                }
                for record in pluginRecords[index] {
                    guard let id = strings[record.id], looksLikeBundleID(id), !seen.contains(id) else { continue }
                    let container = strings[record.container].flatMap { isDataContainer($0) ? $0 : nil }
                    seen.insert(id)
                    entries.append(LaunchServicesEntry(bundleID: id, name: id, containerPath: container, isExtension: true))
                }

                let mapped = entries.filter { $0.containerPath != nil }.count
                if mapped > bestMapped {
                    bestMapped = mapped
                    best = entries
                }
            }

            Log.info(
                "LaunchServices: layout tốt nhất map \(bestMapped) container, \(best.count) mục",
                category: .app
            )
            return best
        }
    }

    private static func findHeapOffset(_ b: UnsafePointer<UInt8>, _ n: Int) -> Int {
        let needle: [UInt8] = [0x3c, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x3e]  // "<string>"
        guard n > needle.count else { return 0 }
        var index = 0
        while index + needle.count <= n {
            if b[index] == needle[0], memcmp(b + index, needle, needle.count) == 0 {
                return index
            }
            index += 1
        }
        return 0
    }

    private static func decodeString(_ b: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let byte = b[offset + index]
            if byte == 0 { return nil }
            bytes[index] = byte
        }
        guard let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func looksLikeBundleID(_ value: String) -> Bool {
        guard value.count >= 4, value.count <= 180, value.contains(".") else { return false }
        guard !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
        }
    }

    private static func isDataContainer(_ value: String) -> Bool {
        let prefixes = [
            "/private/var/mobile/Containers/Data/Application/",
            "/private/var/mobile/Containers/Data/PluginKitPlugin/",
            "/var/mobile/Containers/Data/Application/",
            "/var/mobile/Containers/Data/PluginKitPlugin/",
        ]
        for prefix in prefixes where value.hasPrefix(prefix) {
            let suffix = String(value.dropFirst(prefix.count))
            if suffix.count == 36, UUID(uuidString: suffix) != nil { return true }
        }
        return false
    }

    // MARK: - Đĩa

    private func loadFromDisk() -> [LaunchServicesEntry]? {
        guard let data = try? Data(contentsOf: entriesFileURL),
              let payload = try? JSONDecoder().decode([StoredEntry].self, from: data),
              !payload.isEmpty else { return nil }
        return payload.map {
            LaunchServicesEntry(bundleID: $0.bundleID, name: $0.name, containerPath: $0.containerPath, isExtension: $0.isExtension)
        }
    }

    private func saveToDisk(_ entries: [LaunchServicesEntry]) {
        let payload = entries.map {
            StoredEntry(bundleID: $0.bundleID, name: $0.name, containerPath: $0.containerPath, isExtension: $0.isExtension)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: entriesFileURL, options: .atomic)
    }

    private struct StoredEntry: Codable {
        let bundleID: String
        let name: String
        let containerPath: String?
        let isExtension: Bool
    }
}
