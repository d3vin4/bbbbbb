import SwiftUI

/// Xem nội dung ZIP: chọn mục, giải nén toàn bộ hoặc mục đã chọn.
struct ArchiveSheetView: View {
    let archiveEntry: FileEntry
    let destinationDirectory: URL
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ArchiveEntryInfo] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang đọc ZIP…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(entries) { info in
                    Button {
                        toggle(info)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(info.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(info.path) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name.isEmpty ? info.path : info.name)
                                    .lineLimit(1)
                                if info.isDirectory {
                                    Text("thư mục")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !info.isDirectory {
                                Text(info.size.formatted(.byteCount(style: .file)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("ZIP: \((archiveEntry.name as NSString).deletingPathExtension)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Tất cả") {
                        Task { await extract(nil) }
                    }
                    .disabled(isLoading || isWorking)

                    Button("Mục chọn (\(selected.count))") {
                        Task { await extract(selectedEntries) }
                    }
                    .disabled(selected.isEmpty || isWorking)
                }
            }
            .task {
                await load()
            }
        }
    }

    private var selectedEntries: [ArchiveEntryInfo]? {
        let filtered = entries.filter { selected.contains($0.path) }
        return filtered.isEmpty ? nil : filtered
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = URL(fileURLWithPath: archiveEntry.path)
        do {
            entries = try await Task.detached {
                try ArchiveManager.shared.listEntries(at: url)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extract(_ selection: [ArchiveEntryInfo]?) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Đang giải nén…"

        let url = URL(fileURLWithPath: archiveEntry.path)
        let destination = destinationDirectory
        do {
            let count = try await Task.detached {
                try ArchiveManager.shared.extract(archiveURL: url, entries: selection, to: destination)
            }.value
            statusMessage = "Đã giải nén \(count) mục vào \(destination.lastPathComponent)"
            selected.removeAll()
            onDone()
            Log.info("Archive: giải nén \(count) mục từ \(url.lastPathComponent)", category: .archive)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            Log.error("Archive: \(error.localizedDescription)", category: .archive)
        }
        isWorking = false
    }

    private func toggle(_ info: ArchiveEntryInfo) {
        if selected.contains(info.path) {
            selected.remove(info.path)
        } else {
            selected.insert(info.path)
        }
    }
}
