import Foundation

/// Thông tin tĩnh về các phiên bản iOS mà bbbbbb hỗ trợ.
///
/// App chỉ dùng kỹ thuật worse_query (xem NOTICES.md), đã kiểm chứng trên
/// iOS 26.x và 27.x.
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
