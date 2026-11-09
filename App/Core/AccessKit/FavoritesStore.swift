import Combine
import Foundation

/// Vị trí file/thư mục đã lưu (trong container ứng dụng hoặc App Group).
struct SavedLocation: Codable, Identifiable, Hashable {
    let kind: String
    let identifier: String
    let path: String

    var id: String { "\(kind):\(identifier):\(path)" }
    var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? identifier : last
    }

    var containerKind: ContainerRecord.Kind {
        ContainerRecord.Kind(rawValue: kind) ?? .application
    }

    var containerRecord: ContainerRecord {
        ContainerRecord(identifier: identifier, kind: containerKind, path: path)
    }
}

/// Yêu thích + lịch sử gần đây (UserDefaults, JSON).
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [SavedLocation] = []
    @Published private(set) var recents: [SavedLocation] = []

    private let favoritesKey = "bbbbbb.favorites"
    private let recentsKey = "bbbbbb.recents"
    private let recentsCapacity = 30

    private init() {
        favorites = Self.load(key: favoritesKey) ?? []
        recents = Self.load(key: recentsKey) ?? []
    }

    func isFavorite(_ location: SavedLocation) -> Bool {
        favorites.contains(location)
    }

    func toggleFavorite(_ location: SavedLocation) {
        if let index = favorites.firstIndex(of: location) {
            favorites.remove(at: index)
        } else {
            favorites.insert(location, at: 0)
        }
        persist(favorites, key: favoritesKey)
    }

    func recordVisit(_ location: SavedLocation) {
        recents.removeAll { $0.id == location.id }
        recents.insert(location, at: 0)
        if recents.count > recentsCapacity {
            recents.removeLast(recents.count - recentsCapacity)
        }
        persist(recents, key: recentsKey)
    }

    func clearRecents() {
        recents = []
        persist(recents, key: recentsKey)
    }

    // MARK: - Private

    private func persist(_ items: [SavedLocation], key: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(key: String) -> [SavedLocation]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([SavedLocation].self, from: data)
    }
}
