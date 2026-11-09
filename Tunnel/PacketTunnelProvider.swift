import NetworkExtension

/// Loopback tunnel used to reach on-device system services (lockdownd and friends)
/// from the sandboxed app, replacing the need for a separate LocalDevVPN install.
///
/// The full packet-handling strategy is finalized with the tunnel research
/// (see .research/R4-tunnel.md); this provider establishes the interface now.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.1"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings = ipv4

        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }
}
