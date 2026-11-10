import Combine
import Foundation
import Network
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
    @Published private(set) var serviceReachable = false
    @Published private(set) var externalTunnel: String?

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
            let ours = managers.first { candidate in
                (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == TunnelConstants.providerBundleIdentifier
            }
            manager = ours ?? managers.first
            externalTunnel = managers.first { candidate in
                candidate !== manager && candidate.connection.status == .connected
            }?.localizedDescription
            refreshStatus()
            if isConnected {
                await refreshReachability()
            }
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
            Task { await self.monitorUntilConnected() }
        } catch {
            lastError = error.localizedDescription
            Log.error("Không bật được tunnel: \(error.localizedDescription)", category: .vpn)
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        serviceReachable = false
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

    /// Poll nhanh sau khi bật để trạng thái UI/khả năng sẵn sàng cập nhật tức thì.
    private func monitorUntilConnected(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            refreshStatus()
            if isConnected {
                await refreshReachability()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Probe TCP tới peer (10.7.0.1:49152) — "đã kết nối" chưa chắc dịch vụ đã lên.
    func refreshReachability() async {
        guard isConnected else {
            serviceReachable = false
            return
        }
        serviceReachable = await Self.probePeer(
            host: TunnelConstants.peerHost,
            port: 49152,
            timeout: 0.8
        )
        Log.info(
            "Tunnel: probe \(TunnelConstants.peerHost):49152 → \(serviceReachable ? "OK" : "không phản hồi")",
            category: .vpn
        )
    }

    private static func probePeer(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let gate = ProbeGate()
            let queue = DispatchQueue(label: "com.d3vin4.bbbbbb.tunnel.probe", qos: .utility)

            func finish(_ reachable: Bool) {
                guard gate.tryFinish() else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

/// Chặn resume continuation nhiều lần trong probe.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
