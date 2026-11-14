import Foundation
import UIKit

/// Icon ứng dụng lấy từ API riêng của UIKit.
///
/// SPI đúng có **3 tham số** `_applicationIconImageForBundleIdentifier:format:scale:`
/// (bản 1 tham số luôn trả nil). `perform` không truyền được nhiều tham số nên
/// gọi qua IMP.
enum AppIconExtractor {
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
}
