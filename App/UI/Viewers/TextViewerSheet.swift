import SwiftUI

/// Xem và sửa file văn bản (UTF-8 hoặc Latin-1), lưu đè qua lease container.
struct TextViewerSheet: View {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var originalText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveMessage: String?

    private static let maxBytes = 2 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Đang đọc…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Không mở được",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: text)
                    Button("Lưu") {
                        Task { await save() }
                    }
                    .disabled(isLoading || isSaving || errorMessage != nil || text == originalText)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.thinMaterial)
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
        let url = URL(fileURLWithPath: entry.path)
        do {
            text = try await Task.detached { () -> String in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = (try handle.read(upToCount: Self.maxBytes)) ?? Data()
                if let string = String(data: data, encoding: .utf8) { return string }
                if let string = String(data: data, encoding: .isoLatin1) { return string }
                throw NSError(
                    domain: "TextViewerErrorDomain",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Không decode được văn bản (file nhị phân?)."]
                )
            }.value
            originalText = text
        } catch {
            errorMessage = error.localizedDescription
            Log.error("TextViewer: \(error.localizedDescription)", category: .viewer)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let url = URL(fileURLWithPath: entry.path)
        let content = text
        do {
            try await Task.detached {
                try Data(content.utf8).write(to: url, options: .atomic)
            }.value
            originalText = text
            saveMessage = "Đã lưu \(entry.name)"
            Log.info("TextViewer: lưu \(entry.name) (\(content.utf8.count) bytes)", category: .viewer)
        } catch {
            errorMessage = error.localizedDescription
            Log.error("TextViewer save: \(error.localizedDescription)", category: .viewer)
        }
    }
}
