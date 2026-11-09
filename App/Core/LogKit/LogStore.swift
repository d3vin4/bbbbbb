import Combine
import Foundation

/// Central, persistent log store for the whole app.
///
/// Entries are kept in memory (bounded) for realtime UI and appended to a JSON-lines
/// file in Application Support so history survives relaunches.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private let capacity = 5000
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.d3vin4.bbbbbb.logs.write", qos: .utility)

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("bbbbbb-logs.jsonl")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        loadHistory()
    }

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist(entry)
    }

    func clear() {
        entries.removeAll()
        let url = fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    var exportText: String {
        entries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] [\(entry.category.label)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [LogEntry] = []
        for line in data.split(separator: 0x0A).suffix(capacity) {
            if let entry = try? decoder.decode(LogEntry.self, from: Data(line)) {
                loaded.append(entry)
            }
        }
        entries = loaded
    }

    private func persist(_ entry: LogEntry) {
        let url = fileURL
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
