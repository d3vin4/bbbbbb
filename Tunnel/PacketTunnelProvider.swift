import Darwin
import NetworkExtension
import os.log

/// Loopback tunnel that lets the sandboxed app reach on-device system services
/// (lockdownd, RSD, AirTraffic helpers) without a separate LocalDevVPN install.
///
/// Approach adapted from StosVPN / LocalDevVPN (MIT, © 2025 SideStore Team):
///
/// 1. Bring up a utun interface with the device-side address (default
///    10.7.1.1/32) and include only the peer address (default 10.7.0.1/32);
///    the default route is explicitly excluded so normal networking is untouched.
/// 2. Bounce every packet read from `packetFlow` back into it with source and
///    destination addresses swapped. Dialing 10.7.0.1 therefore reaches
///    services listening on the device itself and replies take the same path.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.apple.mobile.MobileHouseArrest.bbbbbb.tunnel", category: "tunnel")

    private var tunnelIfaceIP = TunnelConstants.defaultIfaceIP
    private var tunnelPeerIP = TunnelConstants.defaultPeerIP

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let value = options?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? providerConfiguration?[TunnelConstants.ifaceIPConfigurationKey] as? String {
            tunnelIfaceIP = value
        }
        if let value = options?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? providerConfiguration?[TunnelConstants.peerIPConfigurationKey] as? String {
            tunnelPeerIP = value
        }

        let iface = CIDREndpoint(tunnelIfaceIP, defaultPrefix: 32)
        let peer = CIDREndpoint(tunnelPeerIP, defaultPrefix: 32)

        log.info("startTunnel iface=\(iface.ip)/\(iface.prefix) peer=\(peer.ip)/\(peer.prefix)")

        let ipv4 = NEIPv4Settings(addresses: [iface.ip], subnetMasks: [iface.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peer.ip, subnetMask: peer.subnetMask)]
        ipv4.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer.ip)
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self?.startPacketLoop()
            completionHandler(nil)
        }
    }

    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }

            var modified = packets
            for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                modified[i].withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    let source = base[3]
                    let destination = base[4]
                    base[3] = destination
                    base[4] = source
                }
            }

            self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.startPacketLoop()
        }
    }
}
