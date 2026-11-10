import SwiftUI

/// Dọn Temp & Cache qua engine Trực tiếp: quét tmp/Library/Caches của container
/// ứng dụng, hiển thị dung lượng, chọn từng/nhiều mục hoặc dọn tất cả.
struct CleanTempView: View {
    /// Khi khác nil, chỉ quét ứng dụng này.
    let focusBundleID: String?

    @StateObject private var model = CleanTempModel()
    @State private var records: [ContainerRecord] = []
    @State private var loadError: String?
    @State private var isLoadingRecords = false
    @State private var confirmCleanAll = false

    var body: some View {
        List {
            statusSection

            ForEach(filteredReports) { report in
                NavigationLink {
                    CleanTempAppView(model: model, report: report)
                } label: {
                    CleanTempRow(report: report)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await model.clean(bundleID: report.record.identifier, entries: nil) }
                    } label: {
                        Label("Dọn", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(focusBundleID == nil ? "Dọn Temp & Cache" : "Dọn theo ứng dụng")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .scanning = model.phase {
                    Button("Dừng") {
                        model.cancelScan()
                    }
                } else {
                    Button("Quét lại") {
                        model.scan(records: filteredRecords)
                    }
                    .disabled(isLoadingRecords || filteredRecords.isEmpty)
                }
            }
        }
        .alert("Dọn tất cả Temp & Cache?", isPresented: $confirmCleanAll) {
            Button("Huỷ", role: .cancel) {}
            Button("Dọn", role: .destructive) {
                Task { _ = await model.cleanAll() }
            }
        } message: {
            Text("Xoá toàn bộ nội dung tmp và Library/Caches của \(filteredReports.count) ứng dụng đã quét.")
        }
        .task {
            await loadRecordsIfNeeded()
        }
    }

    private var filteredReports: [AppTempReport] {
        guard let focusBundleID else { return model.reports }
        return model.reports.filter { $0.record.identifier == focusBundleID }
    }

    private var filteredRecords: [ContainerRecord] {
        guard let focusBundleID else { return records }
        return records.filter { $0.identifier == focusBundleID }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let loadError {
            Section {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else if isLoadingRecords {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang tải danh sách ứng dụng…")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            switch model.phase {
            case .idle:
                Section {
                    Button("Quét dung lượng Temp/Cache") {
                        model.scan(records: filteredRecords)
                    }
                    .disabled(filteredRecords.isEmpty)
                }
            case .scanning(let done, let total):
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Đang quét \(done)/\(total)…")
                            .foregroundStyle(.secondary)
                    }
                }
            case .ready:
                Section {
                    LabeledContent("Tổng dung lượng", value: totalSizeText)
                    Button(role: .destructive) {
                        confirmCleanAll = true
                    } label: {
                        Text("Dọn tất cả (\(filteredReports.count) ứng dụng)")
                    }
                    .disabled(filteredReports.isEmpty)
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var totalSizeText: String {
        filteredReports.reduce(UInt64(0)) { $0 + $1.totalSize }
            .formatted(.byteCount(style: .file))
    }

    private func loadRecordsIfNeeded() async {
        guard records.isEmpty else { return }
        isLoadingRecords = true
        defer { isLoadingRecords = false }

        let report = DirectEngine.shared.capabilityReport()
        guard report.mcmAvailable else {
            loadError = "Cần engine Trực tiếp để dọn Temp/Cache: MCM \(report.mcmAvailable ? "OK" : "thiếu")."
            return
        }
        do {
            records = try await Task.detached { () -> [ContainerRecord] in
                do {
                    return try DirectEngine.shared.fetchApplications(limit: 600)
                } catch {
                    return try DirectEngine.shared.fetchApplicationsDeep(limit: 400)
                }
            }.value
            model.scan(records: filteredRecords)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct CleanTempRow: View {
    let report: AppTempReport

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.record.identifier)
                    .lineLimit(1)
                Text("tmp: \(report.tmpSize.formatted(.byteCount(style: .file))) · cache: \(report.cacheSize.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(report.totalSize.formatted(.byteCount(style: .file)))
                .font(.footnote.monospaced())
                .foregroundStyle(report.totalSize > 0 ? Color.primary : Color.secondary)
        }
    }
}

/// Chi tiết Temp/Cache của một ứng dụng: chọn từng/nhiều mục để xoá.
struct CleanTempAppView: View {
    @ObservedObject var model: CleanTempModel
    let report: AppTempReport

    @State private var selected: Set<String> = []
    @State private var lastResult: String?

    private var currentReport: AppTempReport {
        model.report(forBundleID: report.record.identifier) ?? report
    }

    var body: some View {
        List {
            if !currentReport.tmpEntries.isEmpty {
                Section("tmp (\(currentReport.tmpSize.formatted(.byteCount(style: .file))))") {
                    ForEach(currentReport.tmpEntries) { entry in
                        entryRow(entry)
                    }
                }
            }

            if !currentReport.cacheEntries.isEmpty {
                Section("Library/Caches (\(currentReport.cacheSize.formatted(.byteCount(style: .file))))") {
                    ForEach(currentReport.cacheEntries) { entry in
                        entryRow(entry)
                    }
                }
            }

            if currentReport.totalSize == 0 {
                Section {
                    ContentUnavailableView(
                        "Sạch",
                        systemImage: "checkmark.seal",
                        description: Text("Không còn tệp tạm nào để dọn.")
                    )
                }
            }

            if let lastResult {
                Section {
                    Text(lastResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(currentReport.record.identifier)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task { await deleteSelected() }
                } label: {
                    Text("Xoá (\(selected.count))")
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private func entryRow(_ entry: TempEntry) -> some View {
        Button {
            if selected.contains(entry.path) {
                selected.remove(entry.path)
            } else {
                selected.insert(entry.path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(entry.path) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                    if entry.isDirectory {
                        Text("thư mục")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(entry.size.formatted(.byteCount(style: .file)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func deleteSelected() async {
        let current = currentReport
        let targets = (current.tmpEntries + current.cacheEntries).filter { selected.contains($0.path) }
        let result = await model.clean(bundleID: current.record.identifier, entries: targets)
        lastResult = "Đã xoá \(result.deleted) mục (lỗi: \(result.failed))"
        selected.removeAll()
    }
}
