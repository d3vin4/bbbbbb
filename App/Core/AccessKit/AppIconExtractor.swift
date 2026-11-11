import Foundation
import UIKit

/// Lấy icon ứng dụng **không cần Airlift**:
/// 1) SPI của UIKit `_applicationIconImageForBundleIdentifier:` — nhanh.
/// 2) Đọc gói `.app` bằng token worse_query: PNG rời theo Info.plist, hoặc
///    asset catalog (`Assets.car`) qua CoreUI (`CUICatalog`).
enum AppIconExtractor {
    /// Icon qua SPI của UIKit (mọi guard đều kiểm tra trước nên không crash).
    ///
    /// SPI đúng có **3 tham số** `_applicationIconImageForBundleIdentifier:format:scale:`
    /// (bản 1 tham số luôn trả nil) — gọi qua IMP vì `perform` không truyền
    /// được nhiều tham số.
    static func springBoardIcon(bundleID: String) -> UIImage? {
        let fullSelector = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        if UIImage.self.responds(to: fullSelector),
           let metaClass = object_getClass(UIImage.self as AnyObject),
           let imp = class_getMethodImplementation(metaClass, fullSelector) {
            typealias IconFunction = @convention(c) (AnyClass, Selector, NSString, Int, CGFloat) -> Unmanaged<UIImage>?
            let function = unsafeBitCast(imp, to: IconFunction.self)
            for format in [0, 1] {
                if let image = function(UIImage.self as AnyClass, fullSelector, bundleID as NSString, format, 3.0)?
                    .takeUnretainedValue() {
                    return image
                }
            }
        }

        let cls: AnyObject = UIImage.self
        let selector = NSSelectorFromString("_applicationIconImageForBundleIdentifier:")
        guard cls.responds?(to: selector) == true else { return nil }
        guard let result = cls.perform?(selector, with: bundleID as NSString) else { return nil }
        return result.takeUnretainedValue() as? UIImage
    }

    /// Icon đọc từ gói app (gọi khi đang giữ token worse_query của gói).
    static func bundleIcon(appPath: String, info: [String: Any]) -> Data? {
        if let data = looseIconData(appPath: appPath, info: info) {
            return data
        }
        if let name = info["CFBundleIconName"] as? String,
           let data = catalogIconData(appPath: appPath, name: name) {
            return data
        }
        return nil
    }

    // MARK: - PNG rời

    private static func looseIconNames(_ info: [String: Any]) -> [String] {
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           !files.isEmpty {
            return files
        }
        if let files = info["CFBundleIconFiles"] as? [String], !files.isEmpty {
            return files
        }
        return []
    }

    private static func looseIconData(appPath: String, info: [String: Any]) -> Data? {
        for name in looseIconNames(info).reversed() {
            for suffix in ["@3x.png", "@2x.png", ".png"] {
                let path = (appPath as NSString).appendingPathComponent(name + suffix)
                // Token riêng cho file icon (token thư mục chỉ phủ liệt kê).
                _ = BQCore.escapeTarget(path)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      data.count > 256,
                      let image = UIImage(data: data) else { continue }
                return image.pngData() ?? data
            }
        }
        return nil
    }

    // MARK: - Asset catalog (Assets.car) qua CoreUI

    private static func catalogIconData(appPath: String, name: String) -> Data? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW) != nil,
              let catalogClass = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }

        let allocSelector = NSSelectorFromString("alloc")
        guard let allocated = catalogClass.perform(allocSelector)?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: NSSelectorFromString("initWithURL:")) else { return nil }

        let assetsPath = (appPath as NSString).appendingPathComponent("Assets.car")
        // Token riêng cho Assets.car trước khi mở bằng CoreUI.
        _ = BQCore.escapeTarget(assetsPath)
        let url = URL(fileURLWithPath: assetsPath)
        guard let catalog = allocated.perform(NSSelectorFromString("initWithURL:"), with: url)?
            .takeUnretainedValue() as? NSObject else { return nil }

        let imageSelector = NSSelectorFromString("imageWithName:scaleFactor:deviceIdiom:")
        guard catalog.responds(to: imageSelector) else { return nil }

        typealias ImageFunction = @convention(c) (NSObject, Selector, NSString, CGFloat, Int) -> Unmanaged<NSObject>?
        let function = unsafeBitCast(catalog.method(for: imageSelector), to: ImageFunction.self)
        guard let named = function(catalog, imageSelector, name as NSString, 3.0, 0)?
            .takeUnretainedValue() else { return nil }

        let imageGetter = NSSelectorFromString("image")
        guard named.responds(to: imageGetter),
              let uiImage = named.perform(imageGetter)?.takeUnretainedValue() as? UIImage else { return nil }
        return uiImage.pngData()
    }
}
