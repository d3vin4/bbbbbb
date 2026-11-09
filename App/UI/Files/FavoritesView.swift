import SwiftUI

/// Yêu thích & thư mục mở gần đây.
struct FavoritesView: View {
    @ObservedObject private var store = FavoritesStore.shared

    var body: some View {
        List {
            Section("Yêu thích") {
                if store.favorites.isEmpty {
                    Text("Chưa có mục yêu thích — mở container và chọn “Thêm vào Yêu thích”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.favorites) { location in
                    locationRow(location)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.toggleFavorite(location)
                            } label: {
                                Label("Bỏ", systemImage: "star.slash")
                            }
                        }
                }
            }

            Section("Gần đây") {
                if store.recents.isEmpty {
                    Text("Chưa có lịch sử.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.recents) { location in
                    locationRow(location)
                }
            }

            if !store.recents.isEmpty {
                Section {
                    Button("Xoá lịch sử gần đây", role: .destructive) {
                        store.clearRecents()
                    }
                }
            }
        }
        .navigationTitle("Yêu thích & Gần đây")
    }

    private func locationRow(_ location: SavedLocation) -> some View {
        NavigationLink {
            FileBrowserView(root: location.containerRecord, initialPath: location.path)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .lineLimit(1)
                Text(location.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
