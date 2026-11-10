import SwiftUI
import UIKit

struct AppsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @StateObject private var catalog = AppCatalog()
    @State private var isShowingInstallSheet = false
    @AppStorage("bbbbbb.vpnAutoConnect") private var vpnAutoConnect = true

    var body: some View {
        NavigationStack {
            List {
                Section("Thiết bị") {
                    LabeledContent("Tunnel loopback") {
                        Text(tunnel.statusDescription)
                            .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
                    }
                    LabeledContent("Dịch vụ 10.7.0.1:49152") {
                        Text(tunnel.serviceReachable ? "Phản hồi" : "Chưa phản hồi")
                            .foregroundStyle(tunnel.serviceReachable ? Color.green : Color.secondary)
                    }
                    if let externalTunnel = tunnel.externalTunnel {
                        LabeledContent("Tunnel ngoài") {
                            Text(externalTunnel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Cơ chế truy cập") {
                        Text(AccessMethod.current.title)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Hỗ trợ") {
                        Text(SupportMatrix.supportSummary)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("iOS hiện tại") {
                        Text(SupportMatrix.currentOSVersion)
                            .foregroundStyle(SupportMatrix.isRunningSupportedOS ? .secondary : Color.orange)
                    }
                    NavigationLink {
                        CleanTempView(focusBundleID: nil)
                    } label: {
                        Label("Dọn Temp & Cache", systemImage: "sparkles")
                    }
                    NavigationLink {
                        AppGroupsView()
                    } label: {
                        Label("App Groups", systemImage: "rectangle.3.group")
                    }
                    NavigationLink {
                        FavoritesView()
                    } label: {
                        Label("Yêu thích & Gần đây", systemImage: "star")
                    }
                }

                applicationsSection

                Section("Quy trình thiết lập Airlift") {
                    SetupStepRow(
                        number: 1,
                        title: "Bật tunnel nội bộ",
                        detail: "VPN loopback (10.7.0.1) để ứng dụng kết nối tới dịch vụ hệ thống — không cần cài LocalDevVPN riêng."
                    )
                    SetupStepRow(
                        number: 2,
                        title: "Pair thiết bị",
                        detail: "Mở màn Pairing để lấy mã PIN 6 số (hiển thị cả trên Live Activity), rồi nhập trong Settings ▸ Privacy & Security ▸ Developer Mode."
                    )
                    SetupStepRow(
                        number: 3,
                        title: "Duyệt dữ liệu",
                        detail: "Chọn cơ chế Trực tiếp hoặc AirLift trong Settings; sau đó mở container và App Groups."
                    )
                }
            }
            .navigationTitle("Apps")
            .searchable(text: $catalog.searchText, prompt: "Tìm ứng dụng")
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
                    Button {
                        isShowingInstallSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task {
                await tunnel.load()
                if vpnAutoConnect, tunnel.hasConfiguration, tunnel.status == .disconnected {
                    await tunnel.connect()
                }
                if tunnel.isConnected {
                    await tunnel.refreshReachability()
                }
                await catalog.reloadIfNeeded()
            }
            .sheet(isPresented: $isShowingInstallSheet) {
                InstallIPAView()
            }
            .onChange(of: isShowingInstallSheet) { _, newValue in
                guard !newValue, case .loaded = catalog.state else { return }
                Task { await catalog.reload() }
            }
        }
    }

    @ViewBuilder
    private var applicationsSection: some View {
        Section {
            switch catalog.state {
            case .idle:
                ContentUnavailableView {
                    Label("Chưa tải danh sách ứng dụng", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Cơ chế hiện tại: \(AccessMethod.current.title).")
                } actions: {
                    Button("Tải danh sách") {
                        Task { await catalog.reload() }
                    }
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Đang tải danh sách ứng dụng…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Không tải được", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Thử lại") {
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
                Text("Ứng dụng")
                Spacer()
                if case .loaded = catalog.state {
                    Text("\(catalog.filteredApps.count)")
                        .foregroundStyle(.secondary)
                }
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

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
