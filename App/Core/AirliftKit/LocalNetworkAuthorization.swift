import Foundation
import Network

/// Triggers the Local Network permission dialog by briefly advertising and
/// browsing a throwaway Bonjour service. Non-blocking with a short timeout so
/// it never hangs the pairing flow.
///
/// Adopted from AirCard-iOS (MIT License, © 2026 Johnny Franks).
@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Must match an entry in Info.plist NSBonjourServices.
    private let probeType = "_bbbbbbprobe._tcp"

    func request(timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try? NWListener(using: parameters)
            listener?.service = NWListener.Service(name: "bbbbbbProbe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            // Short timeout — if the dialog was already accepted or dismissed,
            // proceed anyway; NetService.publish() will retrigger it if needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(true) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: authorized)
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
    }
}
