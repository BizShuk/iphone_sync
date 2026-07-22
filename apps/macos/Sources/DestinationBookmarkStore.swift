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
    private let settings: MacSettingsStore

    init(settings: MacSettingsStore = MacSettingsStore()) {
        self.settings = settings
    }

    func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        settings.destinationBookmark = data
    }

    func resolve() throws -> URL {
        guard let data = settings.destinationBookmark else {
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
        settings.destinationBookmark = nil
    }
}
