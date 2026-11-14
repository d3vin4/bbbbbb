import AudioToolbox
import Foundation

/// Âm thanh phản hồi khi bấm nút (bật/tắt trong Cài đặt).
enum SoundKit {
    static let enabledKey = "bbbbbb.sound.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Tiếng "tách" nhẹ của hệ thống (1104 = Tock).
    static func tap() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1104)
    }

    /// Tiếng mở/nặng hơn một chút (1520 = pop).
    static func open() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1520)
    }
}
