import Foundation

/// How bbbbbb reaches app containers and App Groups.
///
/// - `auto`: fastest available route — instant app list via MCM (single call),
///   icons fetched in the background through AirLift, disk cache for relauches.
/// - `direct`: on-device MCM queries (MHA-C2 identity) with fallback escape
///   strategies. No pairing or tunnel required.
/// - `airlift`: pairing-based AirLift services (RSD over the loopback tunnel,
///   InstallationProxy / AFC / AirTraffic). Requires a pairing record.
enum AccessMethod: String, CaseIterable, Identifiable {
    case auto
    case direct
    case airlift

    static let storageKey = "bbbbbb.accessMethod"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Tự động (nhanh nhất)"
        case .direct: return "Trực tiếp"
        case .airlift: return "AirLift"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Tự chọn đường nhanh nhất: danh sách app tức thì qua MCM (không chờ resolve container), icon tải nền qua AirLift (nếu có pairing + tunnel), và cache để mở lại siêu nhanh."
        case .direct:
            return "Truy vấn container trực tiếp trên máy (MHA-C2 + chiến lược dự phòng). Không cần pairing."
        case .airlift:
            return "Qua pairing/AirLift (RSD, InstallationProxy, AFC/AirTraffic). Cần pairing và tunnel loopback."
        }
    }

    /// Currently selected method (shared with @AppStorage via the same key).
    static var current: AccessMethod {
        get {
            AccessMethod(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}
