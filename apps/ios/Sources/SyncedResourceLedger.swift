import Foundation
import SyncCore

/// Everything PhotoKit can tell us about one asset resource before a single
/// byte is read.
///
/// The five identity fields match what `ResourceIdentity.make` hashes, so a
/// resource can be recognised — and offered to the Mac — without exporting it.
struct PhotoResourceIdentity: Equatable, Sendable {
    let assetLocalIdentifier: String
    let assetCreationDate: Date?
    let assetModificationDate: Date?
    let resourceType: String
    let originalFilename: String
    let duplicateOrdinal: Int
    let role: String?

    func storageKey(sourceBindingID: String) -> String {
        [
            sourceBindingID,
            assetLocalIdentifier,
            resourceType,
            originalFilename,
            String(duplicateOrdinal),
        ].joined(separator: "\u{0}")
    }
}

/// Durable record of resources a paired Mac has already confirmed.
///
/// Without it every run re-exported each original to a temporary file and
/// hashed it just to be told the Mac already had it, so a background window
/// spent its whole budget on the oldest photos and never reached the newest.
/// A remembered descriptor carries the content hash and size the Mac needs,
/// which lets a later run offer the resource first and export only when the
/// receiver actually asks for the bytes.
///
/// Entries are keyed by the destination binding, so re-pointing the Mac at a
/// different folder invalidates the whole ledger instead of trusting it.
final class SyncedResourceLedger: @unchecked Sendable {
    private struct StoredRecord: Codable {
        let key: String
        let assetModificationDate: Date?
        let descriptor: ResourceDescriptor
    }

    private static let compactionThreshold = 2_000

    private let fileURL: URL
    private let queue = DispatchQueue(
        label: "com.shuk.iphonesync.ios.synced-resource-ledger"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var records: [String: StoredRecord] = [:]
    private var isLoaded = false
    private var appendsSinceCompaction = 0

    init(fileURL: URL = SyncedResourceLedger.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SyncedResources", isDirectory: true)
            .appendingPathComponent("synced-resources.jsonl", isDirectory: false)
    }

    /// The descriptor a previous run had confirmed, or `nil` when the resource
    /// is unknown or the asset has been edited since.
    func confirmedDescriptor(
        for identity: PhotoResourceIdentity,
        sourceBindingID: String
    ) -> ResourceDescriptor? {
        queue.sync {
            loadIfNeeded()
            guard let record = records[identity.storageKey(sourceBindingID: sourceBindingID)],
                  record.assetModificationDate == identity.assetModificationDate else {
                return nil
            }
            return record.descriptor
        }
    }

    func record(
        _ descriptor: ResourceDescriptor,
        for identity: PhotoResourceIdentity,
        sourceBindingID: String
    ) {
        let record = StoredRecord(
            key: identity.storageKey(sourceBindingID: sourceBindingID),
            assetModificationDate: identity.assetModificationDate,
            descriptor: descriptor
        )
        queue.async { [self] in
            loadIfNeeded()
            records[record.key] = record
            append(record)
        }
    }

    /// Drops a remembered resource so the next run rebuilds it from the file.
    func forget(
        _ identity: PhotoResourceIdentity,
        sourceBindingID: String
    ) {
        let key = identity.storageKey(sourceBindingID: sourceBindingID)
        queue.async { [self] in
            loadIfNeeded()
            guard records.removeValue(forKey: key) != nil else { return }
            compact()
        }
    }

    func clear() {
        queue.async { [self] in
            records = [:]
            isLoaded = true
            appendsSinceCompaction = 0
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Waits for every queued write, so callers that must observe a fully
    /// flushed file (tests, teardown) do not race the serial queue.
    func flush() {
        queue.sync {}
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(
                StoredRecord.self,
                from: Data(line)
            ) else { continue }
            records[record.key] = record
        }
    }

    private func append(_ record: StoredRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        write(line)
        appendsSinceCompaction += 1
        if appendsSinceCompaction >= Self.compactionThreshold {
            compact()
        }
    }

    /// Rewrites the file with one line per live record, dropping the
    /// superseded appends an append-only log accumulates.
    private func compact() {
        appendsSinceCompaction = 0
        var payload = Data()
        for record in records.values.sorted(by: { $0.key < $1.key }) {
            guard var line = try? encoder.encode(record) else { continue }
            line.append(0x0A)
            payload.append(line)
        }
        createFile(contents: payload)
    }

    private func write(_ data: Data) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            createFile(contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    }

    private func createFile(contents: Data) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: contents,
            attributes: [
                // Scheduled runs can start while the device is locked; the
                // ledger must stay readable after the first unlock since boot.
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
    }
}
