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

    @discardableResult
    func save(_ url: URL) throws -> URL {
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resolved = try DestinationRootResolver.resolve(url)
        return try persist(resolved)
    }

    func resolve() throws -> URL {
        guard let data = settings.destinationBookmark else {
            throw DestinationBookmarkError.missing
        }
        let bookmarked = try resolveBookmark(data)
        let accessStarted = bookmarked.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                bookmarked.stopAccessingSecurityScopedResource()
            }
        }

        let resolved = try DestinationRootResolver.resolve(bookmarked)
        guard bookmarked.standardizedFileURL.path != resolved.path else {
            return bookmarked
        }
        return try persist(resolved)
    }

    func clear() {
        settings.destinationBookmark = nil
    }

    private func persist(_ url: URL) throws -> URL {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let bookmarked = try resolveBookmark(data)
        settings.destinationBookmark = data
        return bookmarked
    }

    private func resolveBookmark(_ data: Data) throws -> URL {
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
}
