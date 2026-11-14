import Foundation

enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

enum LogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case app
    case worseQuery
    case fileManager
    case archive
    case viewer
    case cleanTemp
    case ui

    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: return "App"
        case .worseQuery: return "worse_query"
        case .fileManager: return "File Manager"
        case .archive: return "Archive"
        case .viewer: return "Viewer"
        case .cleanTemp: return "Clean Temp"
        case .ui: return "UI"
        }
    }

    var symbolName: String {
        switch self {
        case .app: return "app"
        case .worseQuery: return "internaldrive"
        case .fileManager: return "folder"
        case .archive: return "archivebox"
        case .viewer: return "doc.text.magnifyingglass"
        case .cleanTemp: return "sparkles"
        case .ui: return "rectangle.on.rectangle"
        }
    }
}

struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
}
