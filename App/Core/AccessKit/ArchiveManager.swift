import Foundation
import ZIPFoundation

struct ArchiveEntryInfo: Identifiable, Hashable {
    let path: String
    let size: UInt64
    let isDirectory: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// ZIP: liệt kê, giải nén (toàn bộ hoặc mục chọn), nén file/thư mục.
/// Dựa trên ZIPFoundation (MIT, © Thomas Zoechling).
final class ArchiveManager {
    static let shared = ArchiveManager()

    private init() {}

    // MARK: - Reading

    func listEntries(at archiveURL: URL) throws -> [ArchiveEntryInfo] {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var entries: [ArchiveEntryInfo] = []
        for entry in archive {
            entries.append(
                ArchiveEntryInfo(
                    path: entry.path,
                    size: entry.uncompressedSize,
                    isDirectory: entry.type == .directory
                )
            )
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Extracts all entries (nil) or the selected ones into `destinationDirectory`.
    /// Returns the number of extracted entries.
    func extract(archiveURL: URL, entries selected: [ArchiveEntryInfo]?, to destinationDirectory: URL) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let archive = try Archive(url: archiveURL, accessMode: .read)

        if let selected {
            var extracted = 0
            for info in selected {
                guard let entry = archive[info.path] else { continue }
                let target = destinationDirectory.appendingPathComponent(entry.path)
                if entry.type == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try archive.extract(entry, to: target)
                }
                extracted += 1
            }
            return extracted
        }

        let total = listEntries(at: archiveURL).count
        try fileManager.unzipItem(at: archiveURL, to: destinationDirectory)
        return total
    }

    // MARK: - Writing

    func createArchive(items: [URL], destinationURL: URL, keepParent: Bool) throws {
        let fileManager = FileManager.default
        guard !items.isEmpty else { return }
        try? fileManager.removeItem(at: destinationURL)

        if items.count == 1 {
            try fileManager.zipItem(
                at: items[0],
                to: destinationURL,
                shouldKeepParent: keepParent,
                compressionMethod: .deflate
            )
            return
        }

        let archive = try Archive(url: destinationURL, accessMode: .create)
        for item in items {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try addDirectoryContents(item, inside: archive, fileManager: fileManager)
            } else {
                try archive.addEntry(
                    with: item.lastPathComponent,
                    fileURL: item,
                    compressionMethod: .deflate
                )
            }
        }
    }

    private func addDirectoryContents(_ root: URL, inside archive: Archive, fileManager: FileManager) throws {
        let basePath = root.deletingLastPathComponent().path
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [])
        while let item = enumerator?.nextObject() as? URL {
            let relative = String(item.path.dropFirst(basePath.count + 1))
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try archive.addEntry(
                    with: relative + "/",
                    type: .directory,
                    uncompressedSize: 0,
                    provider: { _, _ in Data() }
                )
            } else {
                try archive.addEntry(
                    with: relative,
                    fileURL: item,
                    compressionMethod: .deflate
                )
            }
        }
    }
}
