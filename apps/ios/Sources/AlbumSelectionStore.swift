import Foundation

struct PhotoAlbum: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
}

struct AlbumSelectionStore {
    private let defaults: UserDefaults
    private let key = "selectedPhotoAlbums"
    private let legacyKey = "selectedPhotoAlbum"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PhotoAlbum] {
        if let data = defaults.data(forKey: key),
           let albums = try? JSONDecoder().decode([PhotoAlbum].self, from: data) {
            return deduplicated(albums)
        }
        guard let data = defaults.data(forKey: legacyKey),
              let album = try? JSONDecoder().decode(PhotoAlbum.self, from: data) else {
            return []
        }
        return [album]
    }

    func save(_ albums: [PhotoAlbum]) {
        defaults.set(try? JSONEncoder().encode(deduplicated(albums)), forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private func deduplicated(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        var seen: Set<String> = []
        return albums.filter { seen.insert($0.id).inserted }
    }
}
