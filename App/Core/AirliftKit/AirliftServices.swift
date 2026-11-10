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
/// services (InstallationProxy, SpringBoardServices). The dial flow
/// (RemoteXPC on 10.7.0.1:49152, then raw RPPairing fallback) follows
/// AirCard-iOS / idevice (MIT).
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
        return try withSession { session in
            try browseApplications(with: session.installationProxy())
        }
    }

    /// Danh sách app + icon trong MỘT tunnel duy nhất (đường nhanh nhất cho AirLift).
    func fetchAppCatalog(iconLimit: Int = 80) async throws -> (apps: [AirliftAppInfo], icons: [String: Data]) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([AirliftAppInfo], [String: Data]), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.fetchAppCatalogSync(iconLimit: iconLimit)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchAppCatalogSync(iconLimit: Int) throws -> (apps: [AirliftAppInfo], icons: [String: Data]) {
        guard AirliftEngine.shared.hasPairing else {
            throw AirliftServicesError.noPairing
        }

        return try withSession { session in
            let ipClient = try session.installationProxy()
            let apps = try browseApplications(with: ipClient)

            var icons: [String: Data] = [:]
            if iconLimit > 0, let springboard = try? session.springboard() {
                var failures = 0
                for bundleID in apps.map(\.bundleID).prefix(iconLimit) {
                    var dataPointer: UnsafeMutableRawPointer?
                    var length: UInt64 = 0
                    let status = bundleID.withCString { bundleC in
                        springboard_services_get_icon(springboard, bundleC, &dataPointer, &length)
                    }
                    if let status {
                        if failures < 3 {
                            Log.warning("AirLift icon \(bundleID): \(describe(status))", category: .airlift)
                        }
                        failures += 1
                        continue
                    }
                    if let dataPointer, length > 0 {
                        icons[bundleID] = Data(bytes: dataPointer, count: Int(length))
                        idevice_data_free(dataPointer.assumingMemoryBound(to: UInt8.self), length)
                    }
                }
            }

            Log.info("AirLift: catalog \(apps.count) app, \(icons.count) icon (một tunnel)", category: .airlift)
            return (apps, icons)
        }
    }

    /// Browse với client InstallationProxy đã kết nối sẵn.
    private static func browseApplications(with client: OpaquePointer) throws -> [AirliftAppInfo] {
        var rawArrayPointer: UnsafeMutableRawPointer?
        var count: UInt64 = 0
        try check(
            installation_proxy_browse(client, nil, &rawArrayPointer, &count),
            "installation_proxy_browse"
        )
        guard let rawArrayPointer else { return [] }
        defer {
            // Frees each plist node in the array.
            idevice_plist_array_free(
                rawArrayPointer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                count
            )
        }

        let nodes = rawArrayPointer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        var apps: [AirliftAppInfo] = []
        apps.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let node = nodes[index] else { continue }
            if let dictionary = plistDictionary(node),
               let app = AirliftAppInfo(dictionary: dictionary) {
                apps.append(app)
            }
        }

        Log.info("AirLift: InstallationProxy trả về \(apps.count) ứng dụng", category: .airlift)
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Icons

    /// Fetches app icons (PNG data) through SpringBoardServices. Individual
    /// failures are skipped; the whole batch shares one tunnel.
    func fetchIcons(bundleIDs: [String]) async -> [String: Data] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Data], Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.fetchIconsSync(bundleIDs: bundleIDs))
            }
        }
    }

    private static func fetchIconsSync(bundleIDs: [String]) -> [String: Data] {
        guard AirliftEngine.shared.hasPairing, !bundleIDs.isEmpty else { return [:] }

        var icons: [String: Data] = [:]
        var failures = 0
        do {
            let session = try openSession()
            defer { session.close() }
            let client = try session.springboard()

            for bundleID in bundleIDs {
                var dataPointer: UnsafeMutableRawPointer?
                var length: UInt64 = 0
                let status = bundleID.withCString { bundleC in
                    springboard_services_get_icon(client, bundleC, &dataPointer, &length)
                }
                if let status {
                    if failures < 3 {
                        Log.warning("AirLift icon \(bundleID): \(describe(status))", category: .airlift)
                    }
                    failures += 1
                    continue
                }
                if let dataPointer, length > 0 {
                    icons[bundleID] = Data(bytes: dataPointer, count: Int(length))
                    idevice_data_free(dataPointer.assumingMemoryBound(to: UInt8.self), length)
                }
            }
            Log.info("AirLift: lấy được \(icons.count)/\(bundleIDs.count) icon (lỗi: \(failures))", category: .airlift)
        } catch {
            Log.warning("AirLift icon: \(error.localizedDescription)", category: .airlift)
        }
        return icons
    }

    // MARK: - Uninstall

    func uninstall(bundleID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.uninstallSync(bundleID: bundleID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func uninstallSync(bundleID: String) throws {
        guard AirliftEngine.shared.hasPairing else {
            throw AirliftServicesError.noPairing
        }
        let session = try openSession()
        defer { session.close() }
        let client = try session.installationProxy()

        let status = bundleID.withCString { bundleC in
            installation_proxy_uninstall(client, bundleC, nil)
        }
        try check(status, "installation_proxy_uninstall")
        Log.info("AirLift: đã gỡ cài đặt \(bundleID)", category: .airlift)
    }

    // MARK: - Install (pre-signed IPA)

    /// Uploads a local IPA into the AFC jail (/PublicStaging) and installs it
    /// through InstallationProxy. `progress` receives 0…1 from an arbitrary
    /// thread; callers must marshal UI updates to the main actor.
    func installIPA(at localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.installIPASync(localURL: localURL, progress: progress)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func installIPASync(localURL: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard AirliftEngine.shared.hasPairing else {
            throw AirliftServicesError.noPairing
        }
        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64),
              fileSize > 0 else {
            throw AirliftServicesError.failed("Không đọc được file IPA")
        }

        let session = try openSession()
        defer { session.close() }
        let ipClient = try session.installationProxy()

        var afcClient: OpaquePointer?
        try check(
            afc_client_connect_rsd(session.adapterHandle, session.handshakeHandle, &afcClient),
            "afc_client_connect_rsd"
        )
        guard let afcClient else {
            throw AirliftServicesError.failed("AFC client rỗng")
        }
        defer { afc_client_free(afcClient) }

        if let mkdirError = "/PublicStaging".withCString({ afc_make_directory(afcClient, $0) }) {
            Log.warning("AirLift: tạo /PublicStaging: \(describe(mkdirError))", category: .airlift)
        }

        let remotePath = "/PublicStaging/bbbbbb-\(Int(Date().timeIntervalSince1970)).ipa"

        var afcFile: OpaquePointer?
        try check(
            remotePath.withCString { afc_file_open(afcClient, $0, 3 /* AfcWrOnly */, &afcFile) },
            "afc_file_open"
        )
        guard let afcFile else {
            throw AirliftServicesError.failed("AFC file handle rỗng")
        }

        var uploadFinished = false
        defer {
            if !uploadFinished {
                _ = afc_file_close(afcFile)
            }
        }

        let source = try FileHandle(forReadingFrom: localURL)
        defer { try? source.close() }

        var uploaded: UInt64 = 0
        while true {
            let chunk = try source.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            let status: UnsafeMutablePointer<IdeviceFfiError>? = chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return afc_file_write(afcFile, base, UInt64(chunk.count))
            }
            try check(status, "afc_file_write")
            uploaded += UInt64(chunk.count)
            progress(min(0.7, 0.7 * (Double(uploaded) / Double(fileSize))))
        }
        try check(afc_file_close(afcFile), "afc_file_close")
        uploadFinished = true
        Log.info("AirLift: upload IPA xong (\(uploaded)/\(fileSize) bytes) → \(remotePath)", category: .airlift)

        let relay = InstallProgressRelay(handler: progress)
        let context = Unmanaged.passUnretained(relay).toOpaque()
        let installStatus = remotePath.withCString { pathC in
            installation_proxy_install_with_callback(ipClient, pathC, nil, installProgressCallback, context)
        }
        try check(installStatus, "installation_proxy_install")
        progress(1.0)
        Log.info("AirLift: cài đặt thành công \(localURL.lastPathComponent)", category: .airlift)

        if let cleanupError = remotePath.withCString({ afc_remove_path_and_contents(afcClient, $0) }) {
            Log.debug("AirLift: dọn staging: \(describe(cleanupError))", category: .airlift)
        }
    }

    // MARK: - Session (one tunnel, lazily connected services)

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

    private final class AirliftSession {
        private let lease: TunnelLease
        private var ipClient: OpaquePointer?
        private var springboardClient: OpaquePointer?

        init(lease: TunnelLease) {
            self.lease = lease
        }

        var adapterHandle: OpaquePointer { lease.adapter }
        var handshakeHandle: OpaquePointer { lease.handshake }

        func installationProxy() throws -> OpaquePointer {
            if let ipClient { return ipClient }
            var client: OpaquePointer?
            try check(
                installation_proxy_connect_rsd(lease.adapter, lease.handshake, &client),
                "installation_proxy_connect_rsd"
            )
            guard let client else {
                throw AirliftServicesError.failed("InstallationProxy client rỗng")
            }
            ipClient = client
            return client
        }

        func springboard() throws -> OpaquePointer {
            if let springboardClient { return springboardClient }
            var client: OpaquePointer?
            try check(
                springboard_services_connect_rsd(lease.adapter, lease.handshake, &client),
                "springboard_services_connect_rsd"
            )
            guard let client else {
                throw AirliftServicesError.failed("SpringBoard client rỗng")
            }
            springboardClient = client
            return client
        }

        func close() {
            if let ipClient { installation_proxy_client_free(ipClient) }
            if let springboardClient { springboard_services_free(springboardClient) }
            lease.close()
        }
    }

    private static func openSession() throws -> AirliftSession {
        AirliftSession(lease: try openTunnel())
    }

    // MARK: - Warm session (giữ tunnel sống giữa các thao tác)

    private static let warmLock = NSLock()
    private static var warmSession: AirliftSession?
    private static var warmSessionDate = Date.distantPast
    private static let warmTTL: TimeInterval = 120

    private static func acquireSession() throws -> (session: AirliftSession, reused: Bool) {
        warmLock.lock()
        let existing = warmSession
        let age = Date().timeIntervalSince(warmSessionDate)
        warmLock.unlock()

        if let existing, age < warmTTL {
            return (existing, true)
        }
        if existing != nil {
            retireWarmSession()
        }
        let fresh = try openSession()
        warmLock.lock()
        warmSession = fresh
        warmSessionDate = Date()
        warmLock.unlock()
        return (fresh, false)
    }

    private static func retireWarmSession() {
        warmLock.lock()
        let session = warmSession
        warmSession = nil
        warmLock.unlock()
        session?.close()
    }

    /// Đóng tunnel ấm (gọi khi VPN ngắt).
    static func dropWarmSession() {
        retireWarmSession()
    }

    /// Tunnel chết giữa chừng → bỏ session ấm và thử lại một lần với tunnel mới.
    private static func withSession<T>(_ body: (AirliftSession) throws -> T) throws -> T {
        let first = try acquireSession()
        do {
            return try body(first.session)
        } catch {
            retireWarmSession()
            guard first.reused else { throw error }
            Log.warning("AirLift: session ấm lỗi — thử lại với tunnel mới (\(error.localizedDescription))", category: .airlift)
            let fresh = try acquireSession()
            return try body(fresh.session)
        }
    }

    /// Chuẩn bị sẵn tunnel sau khi VPN phản hồi — lần browse đầu tiên tức thì.
    func prewarmIfPossible() {
        guard AirliftEngine.shared.hasPairing else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let acquired = try Self.acquireSession()
                if !acquired.reused {
                    Log.info("AirLift: prewarm tunnel xong", category: .airlift)
                }
            } catch {
                Log.debug("AirLift: prewarm bỏ qua (\(error.localizedDescription))", category: .airlift)
            }
        }
    }

    // MARK: - Tunnel

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

// MARK: - Install progress C bridge

/// Bridges the install progress C callback back into Swift.
private final class InstallProgressRelay {
    let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(percent: UInt64) {
        handler(min(1.0, 0.7 + 0.3 * (Double(percent) / 100.0)))
    }
}

private let installProgressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { percent, context in
    guard let context else { return }
    let relay = Unmanaged<InstallProgressRelay>.fromOpaque(context).takeUnretainedValue()
    relay.report(percent: percent)
}
