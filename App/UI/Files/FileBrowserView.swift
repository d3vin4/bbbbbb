import SwiftUI
import UIKit

/// Duyệt file trong container ứng dụng / App Group qua engine Trực tiếp.
struct FileBrowserView: View {
    @StateObject private var model: FileBrowserModel

    @State private var createName = ""
    @State private var isCreatingFolder = false
    @State private var isCreatingFile = false
    @State private var renameTarget: FileEntry?
    @State private var renameText = ""
    @State private var deleteTargets: [FileEntry] = []
    @State private var isConfirmingDelete = false
    @State private var infoText: String?
    @State private var isShowingInfo = false
    @State private var archiveTarget: FileEntry?
    @State private var viewerTarget: FileEntry?
    @State private var quickLookTarget: FileEntry?

    init(root: ContainerRecord, initialPath: String? = nil) {
        _model = StateObject(wrappedValue: FileBrowserModel(root: root, initialPath: initialPath))
    }

    var body: some View {
        List {
            if case .failed(let message) = model.phase {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Thử lại") {
                        Task { await model.reload() }
                    }
                }
            }

            ForEach(model.displayedEntries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FileBrowserView(root: model.root, initialPath: entry.path)
                    } label: {
                        row(entry)
                    }
                    .contextMenu {
                        contextMenu(for: entry)
                    }
                } else {
                    row(entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if entry.fileExtension == "zip" {
                                archiveTarget = entry
                            } else {
                                Task { await showInfo(entry) }
                            }
                        }
                        .contextMenu {
                            contextMenu(for: entry)
                        }
                }
            }

            if model.phase == .ready && model.displayedEntries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Trống",
                        systemImage: "folder",
                        description: Text(model.searchText.isEmpty
                            ? "Không có mục nào trong thư mục."
                            : "Không có kết quả cho “\(model.searchText)”.")
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: "Tìm trong thư mục")
        .refreshable {
            await model.reload()
        }
        .toolbar {
            toolbarContent
        }
        .task {
            await model.reload()
        }
        .alert("Thư mục mới", isPresented: $isCreatingFolder) {
            TextField("Tên thư mục", text: $createName)
            Button("Huỷ", role: .cancel) { createName = "" }
            Button("Tạo") {
                let name = createName
                createName = ""
                Task { await model.createFolder(named: name) }
            }
        }
        .alert("Tệp mới", isPresented: $isCreatingFile) {
            TextField("Tên tệp (kèm phần mở rộng)", text: $createName)
            Button("Huỷ", role: .cancel) { createName = "" }
            Button("Tạo") {
                let name = createName
                createName = ""
                Task { await model.createFile(named: name) }
            }
        }
        .alert("Đổi tên", isPresented: renameBinding) {
            TextField("Tên mới", text: $renameText)
            Button("Huỷ", role: .cancel) { renameTarget = nil }
            Button("Đổi tên") {
                if let target = renameTarget {
                    let name = renameText
                    renameTarget = nil
                    Task { await model.rename(target, to: name) }
                }
            }
        }
        .alert("Xoá \(deleteTargets.count) mục?", isPresented: $isConfirmingDelete) {
            Button("Huỷ", role: .cancel) { deleteTargets = [] }
            Button("Xoá", role: .destructive) {
                let targets = deleteTargets
                deleteTargets = []
                Task { await model.delete(targets) }
            }
        } message: {
            Text(deleteTargets.map(\.name).prefix(5).joined(separator: ", "))
        }
        .alert("Lỗi", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $isShowingInfo) {
            infoSheet
        }
        .sheet(item: $archiveTarget) { entry in
            ArchiveSheetView(
                archiveEntry: entry,
                destinationDirectory: URL(fileURLWithPath: model.currentPath),
                onDone: {
                    Task { await model.reload() }
                }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    createName = ""
                    isCreatingFolder = true
                } label: {
                    Label("Thư mục mới", systemImage: "folder.badge.plus")
                }
                Button {
                    createName = ""
                    isCreatingFile = true
                } label: {
                    Label("Tệp mới", systemImage: "doc.badge.plus")
                }
                Divider()
                Button {
                    Task { await model.paste() }
                } label: {
                    Label("Dán", systemImage: "doc.on.clipboard")
                }
                .disabled(model.clipboard == nil)
                Divider()
                Menu {
                    ForEach(FileSortKey.allCases) { key in
                        Button {
                            model.sortKey = key
                        } label: {
                            if model.sortKey == key {
                                Label(key.title, systemImage: "checkmark")
                            } else {
                                Text(key.title)
                            }
                        }
                    }
                    Button {
                        model.sortAscending.toggle()
                    } label: {
                        Label(
                            model.sortAscending ? "Tăng dần" : "Giảm dần",
                            systemImage: "arrow.up.arrow.down"
                        )
                    }
                } label: {
                    Label("Sắp xếp", systemImage: "arrow.up.arrow.down.circle")
                }
                Button {
                    Task { await model.zipCurrentDirectory() }
                } label: {
                    Label("Nén thư mục này thành .zip", systemImage: "doc.zipper")
                }
                Toggle("Hiện file ẩn", isOn: $model.showHidden)
                Toggle("Hiện phần mở rộng", isOn: $model.showExtensions)
                Divider()
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Tải lại", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Rows

    private func row(_ entry: FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: entry))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: entry))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !entry.isDirectory, entry.size > 0 {
                        Text(entry.size.formatted(.byteCount(style: .file)))
                    }
                    if let modified = entry.modified {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func displayName(for entry: FileEntry) -> String {
        guard !entry.isDirectory, !model.showExtensions else { return entry.name }
        let stripped = (entry.name as NSString).deletingPathExtension
        return stripped.isEmpty ? entry.name : stripped
    }

    private func iconName(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch entry.fileExtension {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "plist": return "list.bullet.rectangle"
        case "json": return "curlybraces"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        case "zip": return "doc.zipper"
        case "db", "sqlite", "sqlite3": return "cylinder"
        case "txt", "log", "md": return "doc.text"
        case "ipa": return "shippingbox"
        default: return "doc"
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        Button {
            Task { await showInfo(entry) }
        } label: {
            Label("Thông tin", systemImage: "info.circle")
        }
        Button {
            model.copyToClipboard([entry], mode: .copy)
        } label: {
            Label("Sao chép", systemImage: "doc.on.doc")
        }
        Button {
            model.copyToClipboard([entry], mode: .cut)
        } label: {
            Label("Cắt", systemImage: "scissors")
        }
        Button {
            Task { await model.duplicate(entry) }
        } label: {
            Label("Nhân bản", systemImage: "plus.square.on.square")
        }
        Button {
            Task { await model.zip(entry) }
        } label: {
            Label("Nén thành .zip", systemImage: "doc.zipper")
        }
        Button {
            renameText = entry.name
            renameTarget = entry
        } label: {
            Label("Đổi tên", systemImage: "pencil")
        }
        Button {
            UIPasteboard.general.string = entry.path
        } label: {
            Label("Sao chép đường dẫn", systemImage: "link")
        }
        Divider()
        Button(role: .destructive) {
            deleteTargets = [entry]
            isConfirmingDelete = true
        } label: {
            Label("Xoá", systemImage: "trash")
        }
    }

    // MARK: - Info

    private func showInfo(_ entry: FileEntry) async {
        infoText = await model.fileInfo(for: entry)
        isShowingInfo = true
    }

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                Text(infoText ?? "")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Thông tin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") {
                        isShowingInfo = false
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.clearError() } }
        )
    }
}
