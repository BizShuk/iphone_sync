import Foundation

/// How far a pass over one album got before it was interrupted.
///
/// Assets are walked oldest first, so the creation date of the last finished
/// asset is enough to resume: everything older has already been handled in
/// this pass.
struct AlbumSyncCursor: Codable, Equatable, Sendable {
    let assetLocalIdentifier: String
    let assetCreationDate: Date
}

/// Remembers where each album's pass stopped so a background window that ran
/// out of time resumes instead of restarting at the oldest photo.
///
/// The cursor is cleared as soon as a pass reaches the end of an album, so the
/// next run walks the album in full again and picks up assets that were
/// imported with an older creation date.
final class AlbumSyncCursorStore: @unchecked Sendable {
    private static let persistInterval = 50

    private let fileURL: URL
    private let queue = DispatchQueue(
        label: "com.shuk.iphonesync.ios.album-sync-cursor"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cursors: [String: AlbumSyncCursor] = [:]
    private var isLoaded = false
    private var advancesSincePersist = 0

    init(fileURL: URL = AlbumSyncCursorStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SyncedResources", isDirectory: true)
            .appendingPathComponent("album-cursors.json", isDirectory: false)
    }

    func cursor(albumID: String) -> AlbumSyncCursor? {
        queue.sync {
            loadIfNeeded()
            return cursors[albumID]
        }
    }

    /// Records progress in memory and persists in batches, because a cursor
    /// that is a few assets stale only costs a short re-walk while a write per
    /// asset would cost the very budget this is meant to save.
    func advance(albumID: String, to cursor: AlbumSyncCursor) {
        queue.async { [self] in
            loadIfNeeded()
            cursors[albumID] = cursor
            advancesSincePersist += 1
            if advancesSincePersist >= Self.persistInterval {
                persist()
            }
        }
    }

    func clear(albumID: String) {
        queue.async { [self] in
            loadIfNeeded()
            guard cursors.removeValue(forKey: albumID) != nil else { return }
            persist()
        }
    }

    func clearAll() {
        queue.async { [self] in
            cursors = [:]
            isLoaded = true
            advancesSincePersist = 0
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Writes any batched advances and waits for the queue to drain.
    func flush() {
        queue.sync {
            guard advancesSincePersist > 0 else { return }
            persist()
        }
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode(
                  [String: AlbumSyncCursor].self,
                  from: data
              ) else { return }
        cursors = stored
    }

    private func persist() {
        advancesSincePersist = 0
        guard let payload = try? encoder.encode(cursors) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: payload,
            attributes: [
                // Scheduled runs can start while the device is locked.
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
    }
}
