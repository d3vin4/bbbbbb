import Foundation

/// Constants shared by the app and the embedded PacketTunnel extension.
enum TunnelConstants {
    /// Canonical identity used by the MHA-C2 direct container workflow
    /// (same approach as FilzaSlop). The build may override
    /// PRODUCT_BUNDLE_IDENTIFIER (e.g. the “lite” variant for parallel
    /// installs); the daemon decides what it accepts.
    static let canonicalAppBundleIdentifier = "com.apple.mobile.MobileHouseArrest"

    /// App-side bundle id (never used from the extension, where Bundle.main differs).
    static var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? canonicalAppBundleIdentifier
    }

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
