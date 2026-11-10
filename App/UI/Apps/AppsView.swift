import SwiftUI
import UIKit

/// Màn chính: danh sách ứng dụng đã cài trên máy (tên, icon, container).
struct AppsView: View {
    @StateObject private var catalog = AppCatalog()

    var body: some View {
        NavigationStack {
            List {
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        LogsView()
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task {
                await catalog.reloadIfNeeded()
            }
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
                Text(L.t("Ứng dụng", "Apps"))
                Spacer()
                if case .loaded = catalog.state {
                    Text("\(catalog.filteredApps.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if catalog.isScanningContainers {
                Text(L.t(
                    "Đang quét container để mở được file trong từng ứng dụng…",
                    "Scanning containers so you can open files inside each app…"
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
