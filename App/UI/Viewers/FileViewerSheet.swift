import SwiftUI

/// Bộ định tuyến viewer theo loại file.
struct FileViewerSheet: View {
    let entry: FileEntry

    var body: some View {
        switch ViewerKind.kind(for: entry) {
        case .text:
            TextViewerSheet(entry: entry)
        case .structured(let kind):
            StructuredViewerSheet(entry: entry, kind: kind)
        case .sqlite:
            SQLiteViewerSheet(entry: entry)
        case .hex:
            HexViewerSheet(entry: entry)
        case .image, .video, .audio, .pdf:
            MediaViewerSheet(entry: entry, kind: ViewerKind.kind(for: entry))
        case .quickLook:
            QuickLookSheet(url: URL(fileURLWithPath: entry.path))
                .ignoresSafeArea()
        }
    }
}
