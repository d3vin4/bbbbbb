import Foundation
import SwiftUI

/// Ngôn ngữ giao diện của app.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english
    case vietnamese

    static let storageKey = "bbbbbb.language"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en")
        case .vietnamese: return Locale(identifier: "vi")
        }
    }

    static var current: AppLanguage {
        get {
            AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}

/// Dịch nhanh: `L.t("Tiếng Việt", "Vietnamese")` — mặc định là English.
enum L {
    static var language: AppLanguage { .current }

    static func t(_ vi: String, _ en: String) -> String {
        language == .vietnamese ? vi : en
    }
}
