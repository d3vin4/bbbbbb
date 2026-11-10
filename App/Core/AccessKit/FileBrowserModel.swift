import Combine
import Foundation

/// Một mục trong container (file hoặc thư mục).
struct FileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?
    let isHidden: Bool

    var id: String { path }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

enum FileSortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case date
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Tên"
        case .size: return "Kích thước"
        case .date: return "Ngày"
        case .type: return "Loại"
        }
    }
}

/// Duyệt và thao tác file trong container qua engine Trực tiếp (MHA-C2 lease).
/// Mọi thao tác chạy off-main; lease được BQCore giữ theo container.
@MainActor
final class FileBrowserModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    struct Clipboard: Equatable {
        enum Mode: Equatable {
            case copy
            case cut
        }

        let mode: Mode
        let entries: [FileEntry]
    }

    let root: ContainerRecord
    private(set) var containerRootPath: String

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var currentPath: String
    @Published private(set) var lastError: String?

    @Published var searchText = ""
    @Published var sortKey: FileSortKey = .name {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyKey) }
    }
    @Published var sortAscending = true {
        didSet { UserDefaults.standard.set(sortAscending, forKey: Self.sortAscendingKey) }
    }
    @Published var showHidden = false {
        didSet { UserDefaults.standard.set(showHidden, forKey: Self.showHiddenKey) }
    }
    @Published var showExtensions = false {
        didSet { UserDefaults.standard.set(showExtensions, forKey: Self.showExtensionsKey) }
    }
    @Published var clipboard: Clipboard?

    static let sortKeyKey = "bbbbbb.files.sortKey"
    static let sortAscendingKey = "bbbbbb.files.sortAscending"
    static let showHiddenKey = "bbbbbb.files.showHidden"
    static let showExtensionsKey = "bbbbbb.files.showExtensions"

    init(root: ContainerRecord, initialPath: String? = nil) {
        self.root = root
        self.containerRootPath = root.path
        self.currentPath = initialPath ?? root.path

        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.sortKeyKey),
           let key = FileSortKey(rawValue: raw) {
            sortKey = key
        }
        if defaults.object(forKey: Self.sortAscendingKey) != nil {
            sortAscending = defaults.bool(forKey: Self.sortAscendingKey)
        }
        if defaults.object(forKey: Self.showHiddenKey) != nil {
            showHidden = defaults.bool(forKey: Self.showHiddenKey)
        }
        if defaults.object(forKey: Self.showExtensionsKey) != nil {
            showExtensions = defaults.bool(forKey: Self.showExtensionsKey)
        }
    }

    // MARK: - Presentation

    var displayedEntries: [FileEntry] {
        var result = entries

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.fileExtension.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        if !showHidden {
            result = result.filter { !$0.isHidden }
        }

        let ascending = sortAscending
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch sortKey {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .size:
                return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
            case .date:
                let left = lhs.modified ?? .distantPast
                let right = rhs.modified ?? .distantPast
                return ascending ? left < right : left > right
            case .type:
                let order = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
                if order == .orderedSame {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return result
    }

    var displayTitle: String {
        currentPath == containerRootPath
            ? root.identifier
            : (currentPath as NSString).lastPathComponent
    }

    var parentPath: String? {
        guard currentPath != containerRootPath else { return nil }
        return (currentPath as NSString).deletingLastPathComponent
    }

    // MARK: - Loading

    func reload() async {
        phase = .loading
        let root = self.root
        let requestedPath = currentPath

        do {
            let result = try await Task.detached { () -> (activated: String, entries: [FileEntry]) in
                let activated = try DirectEngine.shared.activate(root)
                let path = requestedPath.isEmpty ? activated : requestedPath
                let fileManager = FileManager.default
                let url = URL(fileURLWithPath: path)
                let keys: [URLResourceKey] = [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
                ]

                if let listing = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: []
                ) {
                    let entries = listing.map { item in
                        let values = try? item.resourceValues(forKeys: Set(keys))
                        return FileEntry(
                            name: item.lastPathComponent,
                            path: item.path,
                            isDirectory: values?.isDirectory ?? false,
                            size: UInt64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate,
                            isHidden: values?.isHidden ?? item.lastPathComponent.hasPrefix(".")
                        )
                    }
                    return (activated, entries)
                }

                // readdir denied: fall back to fsgetpath enumeration.
                let names = BQCore.listDirectoryEntries(path, maxInode: 2_000_000)
                if names.isEmpty {
                    throw NSError(
                        domain: "FileBrowserErrorDomain",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Không đọc được thư mục (quyền hoặc lease)."]
                    )
                }
                let entries = names.map { fullPath in
                    let name = (fullPath as NSString).lastPathComponent
                    return FileEntry(
                        name: name,
                        path: fullPath,
                        isDirectory: false,
                        size: 0,
                        modified: nil,
                        isHidden: name.hasPrefix(".")
                    )
                }
                return (activated, entries)
            }.value

            if containerRootPath.isEmpty {
                containerRootPath = result.activated
            }
            if currentPath.isEmpty {
                currentPath = result.activated
            }
            entries = result.entries
            phase = .ready
            Log.debug("FileBrowser: \(currentPath) — \(result.entries.count) mục", category: .fileManager)
        } catch {
            phase = .failed(error.localizedDescription)
            Log.error("FileBrowser: \(requestedPath) — \(error.localizedDescription)", category: .fileManager)
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Operations

    func createFolder(named name: String) async {
        guard !name.isEmpty else { return }
        let destination = (currentPath as NSString).appendingPathComponent(name)
        await run { _ in
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        }
    }

    func createFile(named name: String) async {
        guard !name.isEmpty else { return }
        let destination = (currentPath as NSString).appendingPathComponent(name)
        await run { _ in
            guard FileManager.default.createFile(atPath: destination, contents: nil) else {
                throw NSError(
                    domain: "FileBrowserErrorDomain",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Không tạo được file."]
                )
            }
        }
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        guard !newName.isEmpty, newName != entry.name else { return }
        let directory = (entry.path as NSString).deletingLastPathComponent
        let destination = (directory as NSString).appendingPathComponent(newName)
        await run { _ in
            try FileManager.default.moveItem(atPath: entry.path, toPath: destination)
        }
    }

    func delete(_ targets: [FileEntry]) async {
        guard !targets.isEmpty else { return }
        await run { _ in
            for entry in targets {
                try FileManager.default.removeItem(atPath: entry.path)
            }
        }
    }

    func duplicate(_ entry: FileEntry) async {
        let directory = (entry.path as NSString).deletingLastPathComponent
        let fileExtension = (entry.name as NSString).pathExtension
        let baseName = (entry.name as NSString).deletingPathExtension

        var candidate = fileExtension.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(fileExtension)"
        var counter = 2
        while FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate)) {
            candidate = fileExtension.isEmpty
                ? "\(baseName) copy \(counter)"
                : "\(baseName) copy \(counter).\(fileExtension)"
            counter += 1
        }
        let destination = (directory as NSString).appendingPathComponent(candidate)

        await run { _ in
            try FileManager.default.copyItem(atPath: entry.path, toPath: destination)
        }
    }

    func copyToClipboard(_ targets: [FileEntry], mode: Clipboard.Mode) {
        clipboard = Clipboard(mode: mode, entries: targets)
    }

    func paste() async {
        guard let clipboard else { return }
        let directory = currentPath
        let mode = clipboard.mode
        let items = clipboard.entries

        await run { _ in
            let fileManager = FileManager.default
            for entry in items {
                let destination = (directory as NSString).appendingPathComponent(entry.name)
                // Replace existing items (file or folder), like a real file manager.
                if fileManager.fileExists(atPath: destination) {
                    try fileManager.removeItem(atPath: destination)
                }
                switch mode {
                case .copy:
                    try fileManager.copyItem(atPath: entry.path, toPath: destination)
                case .cut:
                    try fileManager.moveItem(atPath: entry.path, toPath: destination)
                }
            }
        }
        self.clipboard = nil
    }

    // MARK: - Archive

    /// Zips a single entry next to it (<name>.zip).
    func zip(_ entry: FileEntry) async {
        let source = URL(fileURLWithPath: entry.path)
        let destination = URL(fileURLWithPath: entry.path + ".zip")
        await run { _ in
            try ArchiveManager.shared.createArchive(items: [source], destinationURL: destination, keepParent: true)
        }
    }

    /// Zips multiple entries into `currentPath/<name>.zip`.
    func zip(_ entries: [FileEntry], named name: String) async {
        guard !entries.isEmpty else { return }
        let urls = entries.map { URL(fileURLWithPath: $0.path) }
        var archiveName = name.trimmingCharacters(in: .whitespaces)
        if archiveName.isEmpty { archiveName = "Archive" }
        if !archiveName.lowercased().hasSuffix(".zip") { archiveName += ".zip" }
        let destination = URL(fileURLWithPath: (currentPath as NSString).appendingPathComponent(archiveName))
        await run { _ in
            try ArchiveManager.shared.createArchive(items: urls, destinationURL: destination, keepParent: true)
        }
    }

    /// Zips the current directory into its parent (<dir>.zip).
    func zipCurrentDirectory() async {
        let directory = URL(fileURLWithPath: currentPath)
        let destination = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".zip")
        await run { _ in
            try ArchiveManager.shared.createArchive(items: [directory], destinationURL: destination, keepParent: true)
        }
    }

    func fileInfo(for entry: FileEntry) async -> String {
        await Task.detached {
            let fileManager = FileManager.default
            var lines: [String] = ["Đường dẫn: \(entry.path)"]
            if let attributes = try? fileManager.attributesOfItem(atPath: entry.path) {
                if let size = attributes[.size] as? UInt64 {
                    lines.append("Kích thước: \(size.formatted(.byteCount(style: .file))) (\(size) bytes)")
                }
                if let modified = attributes[.modificationDate] as? Date {
                    lines.append("Sửa đổi: \(modified.formatted(date: .abbreviated, time: .standard))")
                }
                if let created = attributes[.creationDate] as? Date {
                    lines.append("Tạo: \(created.formatted(date: .abbreviated, time: .standard))")
                }
                if let permissions = attributes[.posixPermissions] as? NSNumber {
                    lines.append(String(format: "Quyền: 0o%o", permissions.intValue))
                }
                if let type = attributes[.type] as? String {
                    lines.append("Loại: \(type)")
                }
            }
            if entry.isDirectory, let children = try? fileManager.contentsOfDirectory(atPath: entry.path).count {
                lines.append("Số mục con: \(children)")
            }
            return lines.joined(separator: "\n")
        }.value
    }

    // MARK: - Private

    private func run(_ operation: @escaping (String) throws -> Void) async {
        let path = currentPath
        do {
            try await Task.detached {
                try operation(path)
            }.value
            lastError = nil
            await reload()
        } catch {
            lastError = error.localizedDescription
            Log.error("FileBrowser op: \(error.localizedDescription)", category: .fileManager)
        }
    }
}
