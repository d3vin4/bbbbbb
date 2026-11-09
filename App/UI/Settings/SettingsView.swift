import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LogStore
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var pairing = PairingController.shared

    @AppStorage(AccessMethod.storageKey) private var accessMethod: AccessMethod = .direct
    @AppStorage("bbbbbb.vpnAutoConnect") private var vpnAutoConnect = true
    @State private var probeLines: [String] = []
    @State private var isProbing = false
    @State private var isBrowsingAirlift = false
    @State private var airliftApps: [AirliftAppInfo] = []

    var body: some View {
        List {
            accessSection
            vpnSection
            pairingSection
            logsSection
            versionSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await tunnel.load()
        }
    }

    // MARK: - Sections

    private var accessSection: some View {
        Section("Cơ chế truy cập") {
            Picker("Phương thức", selection: $accessMethod) {
                ForEach(AccessMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            Text(accessMethod.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await runDiagnostics() }
            } label: {
                if isProbing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Đang kiểm tra…")
                    }
                } else {
                    Text("Chạy chẩn đoán trực tiếp")
                }
            }
            .disabled(isProbing)

            ForEach(probeLines, id: \.self) { line in
                Text(line)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vpnSection: some View {
        Section("VPN / Tunnel loopback") {
            LabeledContent("Trạng thái") {
                Text(tunnel.statusDescription)
                    .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
            }
            if let error = tunnel.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Kết nối") {
                    Task { await tunnel.connect() }
                }
                .disabled(tunnel.isConnected || tunnel.isBusy)
                Button("Ngắt") {
                    tunnel.disconnect()
                }
                .disabled(!tunnel.isConnected && !tunnel.isBusy)
            }
            Toggle("Tự động bật khi mở app", isOn: $vpnAutoConnect)
            Text("Tunnel loopback (10.7.0.1) cho phép ứng dụng kết nối tới dịch vụ hệ thống mà không cần cài LocalDevVPN riêng. Khi sideload, cần ký kèm entitlement NetworkExtension.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        Section("Pairing (AirLift)") {
            LabeledContent("Trạng thái") {
                Text(pairing.running ? pairing.pairingStatus : (pairing.hasPairingFile ? "Đã pair" : "Chưa pair"))
                    .foregroundStyle(.secondary)
            }
            if let pin = pairing.pairingPIN {
                Text("PIN: \(pin)")
                    .font(.title2.monospaced().bold())
            }
            if pairing.running {
                Button("Huỷ pairing") {
                    pairing.softCancel()
                }
            } else {
                Button("Pair trực tiếp trên iPhone") {
                    Task {
                        do {
                            _ = try await pairing.startAndWait()
                        } catch {
                            Log.error("Pairing lỗi: \(error.localizedDescription)", category: .pairing)
                        }
                    }
                }
            }
            Text("Mở Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb và nhập PIN ở trên (PIN cũng hiển thị trên Live Activity).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if pairing.hasPairingFile {
                Button(role: .destructive) {
                    PairingController.deletePairingFile()
                } label: {
                    Text("Xoá file pairing")
                }
                Button {
                    Task { await browseAirliftApps() }
                } label: {
                    if isBrowsingAirlift {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang liệt kê qua AirLift…")
                        }
                    } else {
                        Text("Liệt kê ứng dụng qua AirLift")
                    }
                }
                .disabled(isBrowsingAirlift)
                if !airliftApps.isEmpty {
                    Text("AirLift: \(airliftApps.count) ứng dụng")
                    ForEach(airliftApps.prefix(6)) { app in
                        Text("• \(app.name) — \(app.bundleID)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var logsSection: some View {
        Section("Logs") {
            LabeledContent("Số bản ghi", value: "\(store.entries.count)")
            Button(role: .destructive) {
                store.clear()
            } label: {
                Text("Xóa toàn bộ logs")
            }
        }
    }

    private var versionSection: some View {
        Section("Phiên bản") {
            LabeledContent("Ứng dụng", value: Bundle.main.appVersion)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
        }
    }

    // MARK: - Diagnostics

    private func runDiagnostics() async {
        isProbing = true
        defer { isProbing = false }

        let report = DirectEngine.shared.capabilityReport()
        var lines: [String] = [
            "MCM khả dụng: \(report.mcmAvailable ? "Có" : "Không")",
            "Identity MHA-C2: \(report.mhaIdentity ? "Đúng" : "Không đúng (cần bundle id MHA khi ký)")",
            "App Groups entitlement: \(report.appGroups.isEmpty ? "không có" : report.appGroups.joined(separator: ", "))",
        ]

        if report.isMHAReady {
            do {
                let apps = try DirectEngine.shared.fetchApplications(limit: 400)
                lines.append("Ứng dụng tìm thấy: \(apps.count)")
                for app in apps.prefix(4) {
                    lines.append("• \(app.identifier)")
                }
            } catch {
                lines.append("Liệt kê ứng dụng lỗi: \(error.localizedDescription)")
            }
            do {
                let groups = try DirectEngine.shared.fetchAppGroups(limit: 400)
                lines.append("App Group tìm thấy: \(groups.count)")
            } catch {
                lines.append("Liệt kê App Group lỗi: \(error.localizedDescription)")
            }
        }

        if let lastError = BQCore.lastErrorDescription() {
            lines.append("Lỗi gần nhất: \(lastError)")
        }

        probeLines = lines
        for line in lines {
            Log.info("[chẩn đoán] \(line)", category: .badquery)
        }
    }

    private func browseAirliftApps() async {
        isBrowsingAirlift = true
        defer { isBrowsingAirlift = false }
        do {
            let apps = try await AirliftServices.shared.browseApplications()
            airliftApps = apps
            Log.info("AirLift browse: \(apps.count) ứng dụng", category: .airlift)
        } catch {
            airliftApps = []
            Log.error("AirLift browse lỗi: \(error.localizedDescription)", category: .airlift)
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
