import Darwin
import Foundation

/// Installed application discovered through the AirLift route.
struct AirliftAppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let version: String
    let build: String
    let type: String
    let path: String?

    var id: String { bundleID }
}

extension AirliftAppInfo {
    init?(dictionary: [String: Any]) {
        guard let bundleID = dictionary["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return nil
        }
        self.bundleID = bundleID
        self.name = (dictionary["CFBundleDisplayName"] as? String)
            ?? (dictionary["CFBundleName"] as? String)
            ?? bundleID
        self.version = (dictionary["CFBundleShortVersionString"] as? String) ?? ""
        self.build = (dictionary["CFBundleVersion"] as? String) ?? ""
        self.type = (dictionary["ApplicationType"] as? String) ?? "User"
        self.path = dictionary["Path"] as? String
    }
}

enum AirliftServicesError: LocalizedError {
    case noPairing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPairing:
            return "Chưa có pairing — pair trong Settings trước khi dùng AirLift."
        case .failed(let message):
            return message
        }
    }
}

/// Calls the idevice-ffi surface bundled inside AirliftFFI: tunnel + RSD
/// services (InstallationProxy first). The dial flow (RemoteXPC on
/// 10.7.0.1:49152, then raw RPPairing) follows AirCard-iOS / idevice (MIT).
final class AirliftServices {
    static let shared = AirliftServices()

    private static let rsdPort: UInt16 = 49152
    private static let host = TunnelConstants.peerHost
    private static let hostname = "bbbbbb"

    private init() {}

    // MARK: - App catalog

    func browseApplications() async throws -> [AirliftAppInfo] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AirliftAppInfo], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let apps = try Self.browseApplicationsSync()
                    continuation.resume(returning: apps)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func browseApplicationsSync() throws -> [AirliftAppInfo] {
        guard AirliftEngine.shared.hasPairing else {
            throw AirliftServicesError.noPairing
        }

        let tunnel = try openTunnel()
        defer { tunnel.close() }

        var client: OpaquePointer?
        try check(
            installation_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, &client),
            "installation_proxy_connect_rsd"
        )
        guard let client else {
            throw AirliftServicesError.failed("InstallationProxy client rỗng")
        }
        defer { installation_proxy_client_free(client) }

        var rawArrayPointer: UnsafeMutableRawPointer?
        var count: UInt64 = 0
        try check(
            installation_proxy_browse(client, nil, &rawArrayPointer, &count),
            "installation_proxy_browse"
        )
        guard let rawArrayPointer else { return [] }
        let nodes = rawArrayPointer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)

        var apps: [AirliftAppInfo] = []
        apps.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let node = nodes[index] else { continue }
            if let dictionary = plistDictionary(node),
               let app = AirliftAppInfo(dictionary: dictionary) {
                apps.append(app)
            }
            plist_free(node)
        }

        Log.info("AirLift: InstallationProxy trả về \(apps.count) ứng dụng", category: .airlift)
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Tunnel

    private final class TunnelLease {
        let adapter: OpaquePointer
        let handshake: OpaquePointer

        init(adapter: OpaquePointer, handshake: OpaquePointer) {
            self.adapter = adapter
            self.handshake = handshake
        }

        func close() {
            if let error = adapter_close(adapter) {
                idevice_error_free(error)
            }
            rsd_handshake_free(handshake)
        }
    }

    private static func openTunnel() throws -> TunnelLease {
        var pairingFile: OpaquePointer?
        let readStatus = PairingController.pairingFilePath().withCString { path in
            rp_pairing_file_read(path, &pairingFile)
        }
        try check(readStatus, "rp_pairing_file_read")
        guard let pairingFile else {
            throw AirliftServicesError.failed("Không đọc được pairing file")
        }
        defer { rp_pairing_file_free(pairingFile) }

        var failureKind: Int32 = 0
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?

        // 1. RemoteXPC route (proven order from AirCard-iOS / 3105).
        var status = withSockaddr { address, length in
            hostname.withCString { hostnameC in
                tunnel_create_remotexpc_multihost(
                    address, length, hostnameC, pairingFile,
                    nil, nil, nil, 0,
                    &failureKind, &adapter, &handshake
                )
            }
        }
        if let firstFailure = status {
            let message = describe(firstFailure)
            Log.warning("AirLift: RemoteXPC tunnel thất bại (kind=\(failureKind)): \(message)", category: .airlift)
            failureKind = 0
            adapter = nil
            handshake = nil

            // 2. Raw RPPairing fallback on the same port.
            status = withSockaddr { address, length in
                hostname.withCString { hostnameC in
                    tunnel_create_rppairing_multihost(
                        address, length, hostnameC, pairingFile,
                        nil, nil, nil, 0,
                        &failureKind, &adapter, &handshake
                    )
                }
            }
        }
        try check(status, "tunnel_create (kind=\(failureKind))")

        guard let adapter, let handshake else {
            throw AirliftServicesError.failed("Tunnel trả về handle rỗng")
        }
        Log.info("AirLift: tunnel sẵn sàng qua \(host):\(rsdPort)", category: .airlift)
        return TunnelLease(adapter: adapter, handshake: handshake)
    }

    private static func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = rsdPort.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                body(raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: - plist helpers

    private static func plistDictionary(_ node: UnsafeMutableRawPointer) -> [String: Any]? {
        var xmlPointer: UnsafeMutablePointer<CChar>?
        var xmlLength: UInt32 = 0
        guard plist_to_xml(node, &xmlPointer, &xmlLength) == 0, let xmlPointer else {
            return nil
        }
        defer { plist_mem_free(UnsafeMutableRawPointer(xmlPointer)) }

        let data = Data(bytes: xmlPointer, count: Int(xmlLength))
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    // MARK: - Error helpers

    /// Frees `error` and returns a human-readable description.
    private static func describe(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let code = error.pointee.code
        let message = error.pointee.message.map { String(cString: $0) } ?? "unknown"
        idevice_error_free(error)
        return "[\(code)] \(message)"
    }

    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ label: String) throws {
        guard let error else { return }
        throw AirliftServicesError.failed("\(label): \(describe(error))")
    }
}
