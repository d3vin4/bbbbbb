import SwiftUI

/// Xem và sửa plist/JSON: nội dung được chuẩn hoá (plist XML / JSON pretty),
/// lưu chỉ khi parse lại thành công.
struct StructuredViewerSheet: View {
    let entry: FileEntry
    let kind: StructuredKind

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var originalText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveMessage: String?

    private static let maxBytes = 4 * 1024 * 1024

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
                        .font(.system(.caption, design: .monospaced))
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

    // MARK: - Load / Save

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = URL(fileURLWithPath: entry.path)
        let kind = self.kind
        do {
            text = try await Task.detached { () -> String in
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let capped = data.prefix(Self.maxBytes)
                return try Self.normalizedString(from: Data(capped), kind: kind)
            }.value
            originalText = text
        } catch {
            errorMessage = error.localizedDescription
            Log.error("StructuredViewer load: \(error.localizedDescription)", category: .viewer)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let url = URL(fileURLWithPath: entry.path)
        let content = text
        let kind = self.kind
        do {
            text = try await Task.detached { () -> String in
                // Validate + canonicalize before writing.
                let normalized = try Self.normalizedString(from: Data(content.utf8), kind: kind)
                try Data(normalized.utf8).write(to: url, options: .atomic)
                return normalized
            }.value
            originalText = text
            saveMessage = "Đã lưu \(entry.name)"
            Log.info("StructuredViewer: lưu \(entry.name)", category: .viewer)
        } catch {
            errorMessage = error.localizedDescription
            Log.error("StructuredViewer save: \(error.localizedDescription)", category: .viewer)
        }
    }

    private static func normalizedString(from data: Data, kind: StructuredKind) throws -> String {
        switch kind {
        case .plist:
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            guard let string = String(data: xml, encoding: .utf8) else {
                throw NSError(domain: "StructuredViewerErrorDomain", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Plist không chuyển được sang XML."])
            }
            return string
        case .json:
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            guard let string = String(data: pretty, encoding: .utf8) else {
                throw NSError(domain: "StructuredViewerErrorDomain", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "JSON không chuyển được sang UTF-8."])
            }
            return string
        }
    }
}
