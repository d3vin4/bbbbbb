import ActivityKit
import Foundation

/// Shared Live Activity attributes for the pairing session.
///
/// This file is compiled into both the app target and the PairingActivity widget
/// extension, so the activity attributes type matches on both sides.
struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 6-digit code the user must enter in
        /// Settings ▸ Privacy & Security ▸ Developer Mode ▸ Pair with bbbbbb.
        var pin: String
        var phaseLabel: String
        var detail: String
    }

    var deviceName: String
}
