import Foundation

/// Constants shared by the app and the embedded PacketTunnel extension.
enum TunnelConstants {
    /// Bundle identifier of the app. Kept as a literal so the tunnel extension
    /// does not depend on Bundle.main (which differs between app and extension).
    ///
    /// This identity is required by the MHA-C2 direct container workflow
    /// (same approach as 3105 / FilzaSlop). See NOTICES.md.
    static let appBundleIdentifier = "com.apple.mobile.MobileHouseArrest"

    static var providerBundleIdentifier: String {
        appBundleIdentifier + ".PacketTunnel"
    }

    /// providerConfiguration keys consumed by PacketTunnelProvider.
    static let ifaceIPConfigurationKey = "TunnelIfaceIP"
    static let peerIPConfigurationKey = "TunnelPeerIP"

    /// Device side of the loopback tunnel (the utun address).
    static let defaultIfaceIP = "10.7.1.1/32"

    /// The address apps dial; the packet loop bounces it to the device side.
    static let defaultPeerIP = "10.7.0.1/32"

    /// Host AirLift / lockdown clients connect to once the tunnel is up.
    static let peerHost = "10.7.0.1"
}
