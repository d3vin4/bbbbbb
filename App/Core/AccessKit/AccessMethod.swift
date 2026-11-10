import Foundation

/// Cách nạp **danh sách ứng dụng**. Chỉ có 2 cách.
///
/// Mở container / tệp bên trong ứng dụng luôn dùng worse_query (mặc định,
/// không đổi được) — không phụ thuộc lựa chọn này.
enum AccessMethod: String, CaseIterable, Identifiable {
    /// Đọc danh sách ngay trên máy (LaunchServices + container engine).
    case direct
    /// Đọc danh sách qua AirLift đã pair (InstallationProxy).
    case airlift

    static let storageKey = "bbbbbb.accessMethod"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return L.t("Trực tiếp", "Direct")
        case .airlift: return "AirLift"
        }
    }

    var detail: String {
        switch self {
        case .direct:
            return L.t("Đọc danh sách ứng dụng ngay trên máy.", "Read the app list on-device.")
        case .airlift:
            return L.t(
                "Đọc danh sách ứng dụng qua AirLift — cần pair thiết bị + tunnel loopback.",
                "Read the app list over AirLift — needs pairing + loopback tunnel."
            )
        }
    }

    /// Lựa chọn hiện tại (chia sẻ với @AppStorage qua cùng khoá).
    static var current: AccessMethod {
        get {
            AccessMethod(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .direct
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}
