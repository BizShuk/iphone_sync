import Foundation

struct PhotoAlbum: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
}

struct AlbumSelectionStore {
    private let defaults: UserDefaults
    private let key = "selectedPhotoAlbum"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PhotoAlbum? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PhotoAlbum.self, from: data)
    }

    func save(_ album: PhotoAlbum) {
        defaults.set(try? JSONEncoder().encode(album), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
