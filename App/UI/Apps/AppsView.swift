import SwiftUI
import UIKit

/// Màn chính: danh sách ứng dụng đã cài (tên, icon, container).
struct AppsView: View {
    @StateObject private var catalog = AppCatalog()

    var body: some View {
        NavigationStack {
            List {
                if catalog.isScanningContainers {
                    scanProgressRow
                }
                applicationsSection
            }
            .navigationTitle(L.t("Ứng dụng", "Apps"))
            .searchable(text: $catalog.searchText, prompt: L.t("Tìm ứng dụng", "Search apps"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await catalog.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(catalog.state == .loading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(L.t("Hiện", "Show"), selection: $catalog.filter) {
                            ForEach(AppCatalog.AppFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Divider()
                        NavigationLink {
                            LogsView()
                        } label: {
                            Label(L.t("Nhật ký", "Logs"), systemImage: "list.bullet.rectangle")
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label(L.t("Cài đặt", "Settings"), systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                await catalog.reloadIfNeeded()
            }
        }
    }

    /// Thanh tiến trình quét container (0 → 100%).
    private var scanProgressRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(max(catalog.scanFraction, 0), 1))
                HStack {
                    Text(catalog.scanLabel.isEmpty
                         ? L.t("Đang quét container…", "Scanning containers…")
                         : catalog.scanLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((min(max(catalog.scanFraction, 0), 1)) * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var applicationsSection: some View {
        Section {
            switch catalog.state {
            case .idle:
                ContentUnavailableView {
                    Label(
                        L.t("Chưa tải danh sách ứng dụng", "App list not loaded"),
                        systemImage: "square.stack.3d.up"
                    )
                } actions: {
                    Button(L.t("Tải danh sách", "Load list")) {
                        Task { await catalog.reload() }
                    }
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L.t("Đang tải danh sách ứng dụng…", "Loading app list…"))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(L.t("Không tải được", "Couldn't load"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(L.t("Thử lại", "Retry")) {
                        Task { await catalog.reload() }
                    }
                }
            case .loaded:
                ForEach(catalog.filteredApps) { app in
                    NavigationLink {
                        AppDetailView(app: app, catalog: catalog)
                    } label: {
                        AppRow(app: app, icon: catalog.icons[app.bundleID])
                    }
                }
            }
        } header: {
            HStack {
                Text(catalog.filter == .all
                     ? L.t("Ứng dụng", "Apps")
                     : catalog.filter.title)
                Spacer()
                if case .loaded = catalog.state {
                    Text("\(catalog.filteredApps.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if catalog.isScanningContainers {
                Text(L.t(
                    "Đang quét container còn thiếu…",
                    "Scanning for missing containers…"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppRow: View {
    let app: CatalogApp
    let icon: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 32))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
