import AirliftFFI
import Foundation

private let pairingAltIRKKey = "bbbbbbPairingHostAltIRK"

/// Drives the RPPairing host: requests Local Network access, keeps the app
/// alive while the user approves the PIN in Settings, advertises the service
/// over Bonjour and runs the Airlift pairing host off the main thread.
///
/// Flow (iOS 27+): the user taps “Pair trực tiếp trên iPhone”, the PIN appears
/// here and in the Live Activity, and is entered in
/// Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb.
///
/// Adopted from AirCard-iOS (MIT License, © 2026 Johnny Franks).
@MainActor
final class PairingController: ObservableObject {
    static let shared = PairingController()

    private let hostName = "bbbbbb"
    private let hostModel = "Mac17,7"
    private let bindAddress = "0.0.0.0"
    private let liveActivity = PairingLiveActivityManager()

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    @Published private(set) var running = false
    @Published private(set) var pairingStatus = "Chưa pair"
    @Published private(set) var pairingPIN: String?

    nonisolated private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: pairingAltIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: pairingAltIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    enum PairingError: LocalizedError {
        case localNetworkDenied
        case zeroBytes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .localNetworkDenied:
                return "Quyền Local Network đang tắt. Bật trong Settings ▸ bbbbbb ▸ Local Network."
            case .zeroBytes:
                return "File pairing rỗng — hãy chấp nhận yêu cầu pair rồi thử lại."
            case .failed(let message):
                return message
            }
        }
    }

    // MARK: - Pairing file

    nonisolated static func pairingFilePath() -> String {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("bbbbbb_pairing.plist").path
    }

    nonisolated static var pairingFileExists: Bool {
        let path = pairingFilePath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return false }
        return size > 0
    }

    nonisolated static func deletePairingFile() {
        try? FileManager.default.removeItem(atPath: pairingFilePath())
        storedAltIRK = ""
    }

    var hasPairingFile: Bool { Self.pairingFileExists }

    // MARK: - Public API

    /// Start the host and resolve with the pairing-file path, or throw.
    func startAndWait() async throws -> String {
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pairContinuation = continuation
            start()
        }
    }

    func softCancel() {
        stopAdvertising()
        keepAlive.stopAll()
        liveActivity.end(success: false, detail: "Đã huỷ")
        running = false
        pairingPIN = nil
        pairingStatus = "Đã huỷ"
        resolve(.failure(CancellationError()))
    }

    // MARK: - Private

    private func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "Đang khởi động host cục bộ…"
        Log.info("Bắt đầu pairing host (RPPairing)", category: .pairing)

        Task {
            _ = await localNetwork.request(timeout: 0.8)
            guard running else { return }

            keepAlive.startAudio()
            liveActivity.start(deviceName: "bbbbbb")
            pairingStatus = "Đang quảng bá — mở Settings để pair"
            runHost()
        }
    }

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        let altIRK = Self.storedAltIRK
        nonisolated(unsafe) let context = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let status = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairReadyCallback, pairPinCallback, context, &result
                                )
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if status == 0 {
                let issuedAltIRK = cString(result.host_alt_irk_hex)
                if !issuedAltIRK.isEmpty { Self.storedAltIRK = issuedAltIRK }
                let deviceName = cString(result.device_name)
                let filePath = cString(result.pairing_file_path)
                outcome = .success(
                    name: deviceName.isEmpty ? "iPhone" : deviceName,
                    path: filePath.isEmpty ? outPath : filePath
                )
            } else {
                let message = cString(result.error)
                outcome = .failure(message.isEmpty ? "pairing failed (rc=\(status))" : message)
            }
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<PairingController>.fromOpaque(context).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        stopAdvertising()

        switch outcome {
        case let .success(name, path):
            keepAlive.stopAll()
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size == 0 {
                pairingStatus = "Lỗi: file pairing rỗng"
                liveActivity.end(success: false, detail: "File pairing rỗng")
                resolve(.failure(PairingError.zeroBytes))
            } else {
                pairingStatus = "Đã pair: \(name)"
                liveActivity.end(success: true, detail: "Pairing hoàn tất")
                Log.info("Pairing thành công với \(name) — \(size) bytes", category: .pairing)
                resolve(.success(path))
            }
        case let .failure(message):
            keepAlive.stopAll()
            pairingStatus = "Lỗi: \(message)"
            liveActivity.end(success: false, detail: "Pairing thất bại")
            Log.error("Pairing thất bại: \(message)", category: .pairing)
            resolve(.failure(PairingError.failed(message)))
        }

        running = false
        pairingPIN = nil
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let continuation = pairContinuation else { return }
        pairContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Bonjour advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "Đang quảng bá — mở Settings ▸ Privacy & Security ▸ Developer Mode"
        Log.info("Bonjour: \(serviceID) cổng \(port) (\(txt.count) TXT)", category: .pairing)
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "Nhập PIN \(pin) trong Settings ▸ Developer Mode ▸ Pair with bbbbbb"
        liveActivity.update(pin: pin, detail: "Settings ▸ Privacy & Security ▸ Developer Mode")
        Log.info("PIN pairing: \(pin)", category: .pairing)
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

private let pairReadyCallback: ALPairReadyCb = { context, serviceID, port, keys, values, count in
    guard let context, let serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(context).takeUnretainedValue()
    let identifier = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys, let values {
        for index in 0..<Int(count) {
            guard let key = keys[index], let value = values[index] else { continue }
            txt[String(cString: key)] = Data(String(cString: value).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: identifier, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: ALPairPinCb = { pin, context in
    guard let context, let pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(context).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}
