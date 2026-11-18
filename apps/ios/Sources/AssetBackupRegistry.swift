import Foundation

/// Durable per-asset record of which receivers confirmed a full backup.
///
/// Receivers sync at different times, so confirmations accumulate across runs
/// until `DeletionEligibilityPolicy` sees every required receiver. A changed
/// `modificationDate` means the earlier confirmations describe other bytes and
/// the record starts over.
final class AssetBackupRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: AssetBackupRecord] = [:]
    private var isLoaded = false

    init(fileURL: URL = AssetBackupRegistry.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SyncedResources", isDirectory: true)
            .appendingPathComponent("asset-backups.json", isDirectory: false)
    }

    var allRecords: [AssetBackupRecord] {
        withLoaded { Array(records.values) }
    }

    func record(
        _ candidates: Set<PhotoDeletionCandidate>,
        receiverID: String
    ) {
        guard !candidates.isEmpty else { return }
        withLoaded {
            for candidate in candidates {
                let id = candidate.assetLocalIdentifier
                if var existing = records[id],
                   existing.modificationDate == candidate.modificationDate {
                    existing.receiverIDs.insert(receiverID)
                    records[id] = existing
                } else {
                    records[id] = AssetBackupRecord(
                        assetLocalIdentifier: id,
                        modificationDate: candidate.modificationDate,
                        receiverIDs: [receiverID]
                    )
                }
            }
            persist()
        }
    }

    func remove(receiverID: String) {
        withLoaded {
            for (id, var record) in records {
                record.receiverIDs.remove(receiverID)
                records[id] = record.receiverIDs.isEmpty ? nil : record
            }
            persist()
        }
    }

    func remove(assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        withLoaded {
            for id in assetIDs { records[id] = nil }
            persist()
        }
    }

    func clear() {
        withLoaded {
            records = [:]
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func withLoaded<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if !isLoaded {
            isLoaded = true
            if let data = try? Data(contentsOf: fileURL),
               let stored = try? JSONDecoder().decode(
                   [AssetBackupRecord].self,
                   from: data
               ) {
                records = Dictionary(
                    stored.map { ($0.assetLocalIdentifier, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
            }
        }
        return body()
    }

    private func persist() {
        let sorted = records.values.sorted {
            $0.assetLocalIdentifier < $1.assetLocalIdentifier
        }
        guard let payload = try? JSONEncoder().encode(sorted) else { return }
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
