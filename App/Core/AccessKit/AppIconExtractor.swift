import Foundation
import UIKit

/// Icon ứng dụng lấy từ API riêng của UIKit.
///
/// SPI đúng có **3 tham số** `_applicationIconImageForBundleIdentifier:format:scale:`
/// (bản 1 tham số luôn trả nil). `perform` không truyền được nhiều tham số nên
/// gọi qua IMP.
enum AppIconExtractor {
    /// Icon chữ cái: ô vuông màu (theo hash bundle id) + chữ đầu của tên app.
    /// Dùng khi hệ thống không trả icon thật (app không mang identity MHA).
    static func letterTile(bundleID: String, name: String, size: CGFloat = 40) -> UIImage {
        let palette: [UIColor] = [
            .systemBlue, .systemGreen, .systemIndigo, .systemOrange,
            .systemPink, .systemPurple, .systemRed, .systemTeal,
        ]
        var hash: UInt64 = 5381
        for scalar in bundleID.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        let color = palette[Int(hash % UInt64(palette.count))]
        let letter = String(name.first.map { String($0).uppercased() } ?? "?")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.22)
            color.withAlphaComponent(0.22).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.5, weight: .semibold),
                .foregroundColor: color,
            ]
            let textSize = letter.size(withAttributes: attributes)
            letter.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

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
