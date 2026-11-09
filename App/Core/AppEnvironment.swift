import Foundation

/// Static information about the OS versions bbbbbb officially supports.
///
/// bbbbbb targets iOS 27.x (27.0 – 27.2) where the container-access sandbox escape
/// (worse_query lineage) and on-device Developer Mode pairing are available.
enum SupportMatrix {
    static let supportedMajor = 27
    static let supportedMinorRange = 0...2

    static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var isRunningSupportedOS: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == supportedMajor
    }

    static var supportSummary: String {
        "iOS \(supportedMajor).0 – \(supportedMajor).\(supportedMinorRange.upperBound)"
    }
}
