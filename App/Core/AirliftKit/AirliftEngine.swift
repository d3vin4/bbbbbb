import AirliftFFI
import Foundation

/// AirLift access method engine: on-device services reached through a pairing
/// record plus the loopback tunnel (RSD / AirTraffic / AFC), backed by
/// AirliftFFI (Rust).
final class AirliftEngine {
    static let shared = AirliftEngine()

    private let lock = NSLock()
    private var isPrepared = false

    private init() {}

    /// Configures the Rust log bridge and the loopback target host. Call once
    /// early in the app lifecycle.
    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared else { return }
        isPrepared = true

        _ = al_log_init({ _, message in
            guard let message else { return }
            let text = String(cString: message)
            Log.debug("[airlift] \(text)", category: .airlift)
        }, nil)

        setTargetHost(TunnelConstants.peerHost)
        Log.info("Airlift engine sẵn sàng (target \(TunnelConstants.peerHost))", category: .airlift)
    }

    func setTargetHost(_ host: String) {
        _ = host.withCString { al_set_target_host($0) }
    }

    var hasPairing: Bool { PairingController.pairingFileExists }

    /// Resolves the data container path for a bundle identifier through the
    /// pairing tunnel. Blocks — call off the main thread.
    func findAppContainer(bundleID: String) throws -> String {
        guard hasPairing else {
            throw error("Chưa có pairing — pair trong Settings trước.")
        }

        let pairingPath = PairingController.pairingFilePath()
        var container: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let status: Int32 = pairingPath.withCString { pairingC in
            bundleID.withCString { bundleC in
                al_find_app_container(pairingC, bundleC, nil, nil, &container, &outError)
            }
        }

        defer {
            if let container { al_string_free(container) }
            if let outError { al_string_free(outError) }
        }

        guard status == 0, let container else {
            let message = outError.map { String(cString: $0) } ?? "find_app_container rc=\(status)"
            throw error(message)
        }
        return String(cString: container)
    }

    private func error(_ message: String) -> NSError {
        NSError(
            domain: "AirliftEngineErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
