import UIKit

/// Ứng dụng đã cài, đọc từ LaunchServices (dịch vụ hệ thống).
struct InstalledAppInfo: @unchecked Sendable {
    let bundleID: String
    let name: String
    let icon: UIImage?
}

/// Liệt kê ứng dụng đã cài mà không cần identity MHA, không cần tunnel.
///
/// Dùng `LSApplicationWorkspace` (API private của hệ thống) — trả về đủ app
/// kèm tên hiển thị và icon. Mọi lời gọi đều được kiểm tra `responds(to:)`
/// trước nên không crash nếu API biến mất trong iOS mới.
///
/// Lưu ý bộ nhớ: `perform` trả về đối tượng **autoreleased**, nên chỉ được
/// lấy bằng `takeUnretainedValue()`; dùng `takeRetainedValue()` sẽ over-release
/// và crash trong `objc_release`.
enum InstalledAppsProbe {
    static func installedApps() -> [InstalledAppInfo] {
        autoreleasepool {
            guard let workspace = defaultWorkspace() else { return [] }

            let selector = NSSelectorFromString("allInstalledApplications")
            guard workspace.responds(to: selector) else { return [] }
            guard let raw = workspace.perform(selector)?.takeUnretainedValue() else { return [] }

            var proxies: [NSObject] = []
            if let array = raw as? [NSObject] {
                proxies = array
            } else if let set = raw as? NSSet {
                proxies = set.allObjects.compactMap { $0 as? NSObject }
            }

            var result: [InstalledAppInfo] = []
            result.reserveCapacity(proxies.count)
            for proxy in proxies {
                guard let bundleID = stringValue(proxy, keys: ["bundleIdentifier"]) else { continue }
                let name = stringValue(proxy, keys: ["localizedName", "name", "bundleDisplayName"]) ?? bundleID
                let icon = imageValue(proxy, keys: ["icon", "applicationIcon", "bundleIcon"])
                result.append(InstalledAppInfo(bundleID: bundleID, name: name, icon: icon))
            }
            return result
        }
    }

    // MARK: - Private API helpers

    private static func defaultWorkspace() -> NSObject? {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: selector) else { return nil }
        return cls.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func stringValue(_ object: NSObject, keys: [String]) -> String? {
        for key in keys {
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { continue }
            guard let value = object.perform(selector)?.takeUnretainedValue() as? String,
                  !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func imageValue(_ object: NSObject, keys: [String]) -> UIImage? {
        for key in keys {
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { continue }
            if let image = object.perform(selector)?.takeUnretainedValue() as? UIImage {
                return image
            }
        }
        return nil
    }
}
