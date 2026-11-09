import SQLite3
import SwiftUI

/// Đọc SQLite (read-only): danh sách bảng + xem dữ liệu phân trang.
struct SQLiteViewerSheet: View {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss

    @State private var tables: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Đang đọc database…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Không mở được",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if tables.isEmpty {
                    ContentUnavailableView("Không có bảng", systemImage: "cylinder")
                } else {
                    List(tables, id: \.self) { table in
                        NavigationLink {
                            SQLiteTableView(entry: entry, table: table)
                        } label: {
                            Label(table, systemImage: "tablecells")
                        }
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let path = entry.path
        do {
            tables = try await Task.detached { () -> [String] in
                let reader = try SQLiteReader(path: path)
                let result = try reader.query(
                    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
                )
                return result.rows.compactMap { $0.first }
            }.value
            Log.info("SQLiteViewer: \(tables.count) bảng trong \(entry.name)", category: .viewer)
        } catch {
            errorMessage = error.localizedDescription
            Log.error("SQLiteViewer: \(error.localizedDescription)", category: .viewer)
        }
    }
}

// MARK: - Table pager

private struct SQLiteTableView: View {
    let entry: FileEntry
    let table: String

    @State private var columns: [String] = []
    @State private var rows: [[String]] = []
    @State private var isLoading = false
    @State private var canLoadMore = false
    @State private var errorMessage: String?

    private static let pageSize = 50
    private static let columnWidth: CGFloat = 160

    var body: some View {
        Group {
            if isLoading && rows.isEmpty {
                ProgressView("Đang đọc…")
            } else if let errorMessage, rows.isEmpty {
                ContentUnavailableView(
                    "Lỗi",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if rows.isEmpty {
                ContentUnavailableView("Bảng trống", systemImage: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow
                        ForEach(rows.indices, id: \.self) { index in
                            dataRow(rows[index], isEven: index % 2 == 0)
                        }
                        if canLoadMore {
                            Button("Tải thêm") {
                                Task { await loadMore() }
                            }
                            .padding()
                        }
                    }
                }
            }
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMore()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                Text(column)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: Self.columnWidth, alignment: .leading)
                    .padding(6)
                    .background(Color(.secondarySystemBackground))
            }
        }
    }

    private func dataRow(_ values: [String], isEven: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index])
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .frame(width: Self.columnWidth, alignment: .leading)
                    .padding(6)
                    .background(isEven ? Color.clear : Color(.secondarySystemBackground).opacity(0.5))
            }
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let path = entry.path
        let offset = rows.count
        let quotedTable = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let sql = "SELECT * FROM \(quotedTable) LIMIT \(Self.pageSize) OFFSET \(offset)"

        do {
            let result = try await Task.detached { () -> SQLiteReader.ResultSet in
                let reader = try SQLiteReader(path: path)
                return try reader.query(sql)
            }.value
            if columns.isEmpty {
                columns = result.columns
            }
            rows.append(contentsOf: result.rows)
            canLoadMore = result.rows.count == Self.pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Minimal read-only reader

private final class SQLiteReader {
    struct ResultSet {
        let columns: [String]
        let rows: [[String]]
    }

    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let opened = handle else {
            let message: String
            if let handle {
                message = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
            } else {
                message = "sqlite3_open_v2 thất bại (code \(status))"
            }
            throw NSError(
                domain: "SQLiteViewerErrorDomain",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        db = opened
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func query(_ sql: String) throws -> ResultSet {
        guard let db else {
            throw NSError(
                domain: "SQLiteViewerErrorDomain",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Database đã đóng."]
            )
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(
                domain: "SQLiteViewerErrorDomain",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { index -> String in
            guard let name = sqlite3_column_name(statement, Int32(index)) else {
                return "col\(index)"
            }
            return String(cString: name)
        }

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_NULL:
                    row.append("NULL")
                case SQLITE_BLOB:
                    row.append("<BLOB \(sqlite3_column_bytes(statement, Int32(index))) bytes>")
                default:
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        row.append(String(cString: text))
                    } else {
                        row.append("")
                    }
                }
            }
            rows.append(row)
        }
        return ResultSet(columns: columns, rows: rows)
    }
}
