import Foundation

enum StructuredKind {
    case plist
    case json
}

enum ViewerKind {
    case text
    case structured(StructuredKind)
    case hex
    case image
    case video
    case audio
    case pdf
    case quickLook

    static func kind(for entry: FileEntry) -> ViewerKind {
        guard !entry.isDirectory else { return .quickLook }
        switch entry.fileExtension {
        case "plist":
            return .structured(.plist)
        case "json":
            return .structured(.json)
        case "txt", "log", "md", "markdown", "swift", "m", "mm", "h", "c", "cpp", "hpp",
             "js", "ts", "py", "rb", "sh", "conf", "cfg", "ini", "yaml", "yml",
             "html", "htm", "css", "csv", "strings", "pem", "entitlements":
            return .text
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff":
            return .image
        case "mp4", "mov", "m4v":
            return .video
        case "mp3", "m4a", "wav", "aac":
            return .audio
        case "pdf":
            return .pdf
        case "db", "sqlite", "sqlite3", "bin", "dat":
            return .hex
        default:
            return .quickLook
        }
    }

    static func hasRichViewer(for entry: FileEntry) -> Bool {
        if case .quickLook = kind(for: entry) { return false }
        return true
    }
}
