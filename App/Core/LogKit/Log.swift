import Foundation

/// Lightweight logging facade. Safe to call from any thread.
enum Log {
    static func debug(_ message: String, category: LogCategory = .app) {
        write(level: .debug, message: message, category: category)
    }

    static func info(_ message: String, category: LogCategory = .app) {
        write(level: .info, message: message, category: category)
    }

    static func warning(_ message: String, category: LogCategory = .app) {
        write(level: .warning, message: message, category: category)
    }

    static func error(_ message: String, category: LogCategory = .app) {
        write(level: .error, message: message, category: category)
    }

    private static func write(level: LogLevel, message: String, category: LogCategory) {
        let entry = LogEntry(id: UUID(), date: Date(), level: level, category: category, message: message)
        Task { @MainActor in
            LogStore.shared.append(entry)
        }
    }
}
