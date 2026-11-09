import AVKit
import PDFKit
import SwiftUI
import UIKit

/// Ảnh (zoom), video/audio (AVPlayer), PDF (PDFKit).
struct MediaViewerSheet: View {
    let entry: FileEntry
    let kind: ViewerKind

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Đóng") {
                            dismiss()
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .image:
            ZoomableImageView(url: URL(fileURLWithPath: entry.path))
        case .video, .audio:
            VideoPlayer(player: AVPlayer(url: URL(fileURLWithPath: entry.path)))
                .ignoresSafeArea(edges: .bottom)
        case .pdf:
            PDFKitRepresentedView(url: URL(fileURLWithPath: entry.path))
        default:
            ContentUnavailableView("Không hỗ trợ", systemImage: "questionmark")
        }
    }
}

private struct ZoomableImageView: View {
    let url: URL

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = max(1.0, min(8.0, lastScale * value.magnification))
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                }
                        )
                }
            } else {
                ContentUnavailableView("Không đọc được ảnh", systemImage: "photo")
            }
        }
    }
}

private struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil {
            view.document = PDFDocument(url: url)
        }
    }
}
