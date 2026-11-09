import Combine
import Foundation
import NetworkExtension

/// Manages the embedded loopback tunnel (NETunnelProviderManager) from the app.
///
/// The tunnel itself is only functional when the signed build carries the
/// `com.apple.developer.networking.networkextension` (packet-tunnel-provider)
/// entitlement; without it configuration/start fail with a clear status message.
@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
    }

    // MARK: - State

    var isConnected: Bool { status == .connected }
    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }
    var hasConfiguration: Bool { manager != nil }

    var statusDescription: String {
        switch status {
        case .invalid: return "Chưa thiết lập"
        case .disconnected: return "Đã ngắt"
        case .connecting: return "Đang kết nối…"
        case .connected: return "Đã kết nối"
        case .reasserting: return "Đang khôi phục…"
        case .disconnecting: return "Đang ngắt…"
        @unknown default: return "Không rõ"
        }
    }

    // MARK: - Actions

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { candidate in
                (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == TunnelConstants.providerBundleIdentifier
            } ?? managers.first
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            Log.warning("Không đọc được cấu hình tunnel: \(error.localizedDescription)", category: .vpn)
        }
    }

    func connect() async {
        do {
            if manager == nil {
                try await createConfiguration()
            }
            guard let manager else { return }
            try manager.connection.startVPNTunnel()
            lastError = nil
            Log.info("Đã yêu cầu bật tunnel loopback", category: .vpn)
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            Log.error("Không bật được tunnel: \(error.localizedDescription)", category: .vpn)
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        Log.info("Đã yêu cầu ngắt tunnel", category: .vpn)
        refreshStatus()
    }

    // MARK: - Private

    private func createConfiguration() async throws {
        let newManager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.providerBundleIdentifier
        proto.serverAddress = TunnelConstants.peerHost
        proto.providerConfiguration = [
            TunnelConstants.ifaceIPConfigurationKey: TunnelConstants.defaultIfaceIP,
            TunnelConstants.peerIPConfigurationKey: TunnelConstants.defaultPeerIP,
        ]
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "bbbbbb Tunnel"
        newManager.isEnabled = true

        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        manager = newManager
        Log.info("Đã tạo cấu hình tunnel loopback (\(TunnelConstants.defaultPeerIP))", category: .vpn)
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
    }
}
