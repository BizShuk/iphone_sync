import Foundation

enum DestinationBookmarkError: Error, LocalizedError {
    case missing
    case stale

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No destination folder has been selected."
        case .stale:
            return "The saved destination permission is stale. Choose the folder again."
        }
    }
}

struct DestinationBookmarkStore {
    private let defaults: UserDefaults
    private let key = "destinationBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key)
    }

    func resolve() throws -> URL {
        guard let data = defaults.data(forKey: key) else {
            throw DestinationBookmarkError.missing
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw DestinationBookmarkError.stale }
        return url
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
