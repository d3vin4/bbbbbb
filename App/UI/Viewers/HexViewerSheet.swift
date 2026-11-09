import SwiftUI

/// Hex dump theo phân trang (mặc định 256KB mỗi lần tải).
struct HexViewerSheet: View {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String] = []
    @State private var loadedBytes: UInt64 = 0
    @State private var totalSize: UInt64 = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let chunkSize = 256 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && lines.isEmpty {
                    ProgressView("Đang đọc…")
                } else if let errorMessage, lines.isEmpty {
                    ContentUnavailableView(
                        "Không mở được",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                ToolbarItem(placement: .topBarTrailing) {
                    if loadedBytes < totalSize {
                        Button("Tải thêm") {
                            Task { await loadMore() }
                        }
                        .disabled(isLoading)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(loadedBytes.formatted(.byteCount(style: .file))) / \(totalSize.formatted(.byteCount(style: .file)))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoading && !lines.isEmpty {
                        ProgressView()
                    }
                }
                .padding(6)
                .background(.thinMaterial)
            }
            .task {
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let url = URL(fileURLWithPath: entry.path)
        let offset = loadedBytes
        do {
            let chunk = try await Task.detached { () -> (Data, UInt64) in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                let data = (try handle.read(upToCount: Self.chunkSize)) ?? Data()
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? UInt64) ?? 0
                return (data, size)
            }.value

            totalSize = chunk.1
            appendLines(for: chunk.0, baseOffset: offset)
            loadedBytes += UInt64(chunk.0.count)
        } catch {
            errorMessage = error.localizedDescription
            Log.error("HexViewer: \(error.localizedDescription)", category: .viewer)
        }
    }

    private func appendLines(for data: Data, baseOffset: UInt64) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let end = min(index + 16, bytes.count)
            let slice = bytes[index..<end]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = slice.map { byte -> String in
                (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
            }.joined()
            let padded = (hex as NSString).padding(toLength: 47, withPad: " ", startingAt: 0)
            lines.append(String(format: "%08llx", baseOffset + UInt64(index)) + "  " + padded + "  |" + ascii + "|")
            index = end
        }
    }
}
