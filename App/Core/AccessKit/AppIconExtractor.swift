import Foundation
import UIKit

/// Lấy icon ứng dụng **không cần Airlift**:
/// 1) SPI của UIKit `_applicationIconImageForBundleIdentifier:` — nhanh.
/// 2) Đọc gói `.app` bằng token worse_query: PNG rời theo Info.plist, hoặc
///    asset catalog (`Assets.car`) qua CoreUI (`CUICatalog`).
enum AppIconExtractor {
    /// Icon qua SPI của UIKit (mọi guard đều kiểm tra trước nên không crash).
    static func springBoardIcon(bundleID: String) -> UIImage? {
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

        let url = URL(fileURLWithPath: (appPath as NSString).appendingPathComponent("Assets.car"))
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
