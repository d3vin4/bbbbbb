import Foundation

/// Minimal CIDR endpoint helper used by the tunnel extension.
///
/// Simplification of the CIDR handling used by LocalDevVPN / StosVPN
/// (MIT License, © 2025 SideStore Team). Only what the tunnel needs:
/// parse `ip/prefix` and derive the subnet mask.
struct CIDREndpoint {
    let ip: String
    let prefix: Int

    init(_ input: String, defaultPrefix: Int = 32) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)

        let ipPart = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        ip = ipPart.isEmpty ? "0.0.0.0" : ipPart

        if parts.count == 2,
           let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)),
           (0...32).contains(parsed) {
            prefix = parsed
        } else {
            prefix = defaultPrefix
        }
    }

    var subnetMask: String {
        Self.subnetMask(prefix: prefix)
    }

    static func subnetMask(prefix: Int) -> String {
        guard prefix > 0 else { return "0.0.0.0" }
        guard prefix < 32 else { return "255.255.255.255" }
        let mask: UInt32 = ~((UInt32(1) << (32 - prefix)) - 1)
        return "\(mask >> 24).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
    }
}
