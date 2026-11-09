import SwiftUI
import UIKit

/// Danh sách App Groups (engine Trực tiếp / MHA-C2) — hiển thị như Applications.
struct AppGroupsView: View {
    @State private var groups: [ContainerRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Đang tải App Groups…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(groups) { group in
                NavigationLink {
                    AppGroupDetailView(group: group)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.identifier)
                            .lineLimit(1)
                        Text(group.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if !isLoading && groups.isEmpty && errorMessage == nil {
                Section {
                    ContentUnavailableView(
                        "Không có App Group",
                        systemImage: "rectangle.3.group",
                        description: Text("Cần engine Trực tiếp (MHA-C2) và thiết bị đã ký đủ quyền.")
                    )
                }
            }
        }
        .navigationTitle("App Groups")
        .task {
            await load()
        }
    }

    private func load() async {
        guard !isLoading, groups.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let report = DirectEngine.shared.capabilityReport()
        guard report.mcmAvailable && report.mhaIdentity else {
            errorMessage = "Cần engine Trực tiếp (MHA-C2): MCM \(report.mcmAvailable ? "OK" : "thiếu"), identity \(report.mhaIdentity ? "đúng" : "chưa đúng")."
            return
        }
        do {
            groups = try await Task.detached {
                try DirectEngine.shared.fetchAppGroups(limit: 600)
            }.value
            Log.info("AppGroups: tìm thấy \(groups.count) container", category: .badquery)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Chi tiết một App Group: kích hoạt lease và đọc thử.
struct AppGroupDetailView: View {
    let group: ContainerRecord

    @State private var isWorking = false
    @State private var activatedPath: String?
    @State private var entryCount: Int?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Thông tin") {
                Text(group.identifier)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text(group.path)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button("Sao chép đường dẫn") {
                    UIPasteboard.general.string = group.path
                }
            }

            Section("Hành động") {
                NavigationLink {
                    FileBrowserView(root: group)
                } label: {
                    Label("Mở Container", systemImage: "folder")
                }
                Button {
                    Task { await activate() }
                } label: {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang xử lý…")
                        }
                    } else {
                        Text("Kích hoạt và đọc thử")
                    }
                }
                .disabled(isWorking)

                if let activatedPath {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Đã kích hoạt")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(activatedPath)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let entryCount {
                    Text("Mục trong container: \(entryCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("App Group")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func activate() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await Task.detached { () -> (String, Int) in
                let path = try DirectEngine.shared.activate(group)
                let entries = (try? DirectEngine.shared.listDirectory(at: path)) ?? []
                return (path, entries.count)
            }.value
            activatedPath = result.0
            entryCount = result.1
            Log.info("Direct: kích hoạt App Group \(group.identifier) → \(result.0) (\(result.1) mục)", category: .badquery)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
