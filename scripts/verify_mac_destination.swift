import Foundation

@main
enum VerifyMacDestination {
    static func main() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "iphone-sync-destination-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: testRoot) }

        let target = testRoot.appendingPathComponent("target", isDirectory: true)
        let symbolicLink = testRoot.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: target
        )

        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSymbolicLink = try DestinationRootResolver.resolve(symbolicLink)
        precondition(resolvedSymbolicLink == resolvedTarget)

        let suiteName = "com.shuk.iphonesync.destination-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MacSettingsStore(defaults: defaults)
        let bookmarkStore = DestinationBookmarkStore(settings: settings)
        let selected = try bookmarkStore.save(symbolicLink)
        precondition(
            selected.resolvingSymlinksInPath().standardizedFileURL
                == resolvedTarget
        )
        let restored = try bookmarkStore.resolve()
        precondition(
            restored.resolvingSymlinksInPath().standardizedFileURL
                == resolvedTarget
        )

        let receivingFolder = restored.appendingPathComponent(
            "iPhoneSync",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: receivingFolder,
            withIntermediateDirectories: false
        )
        precondition(fileManager.fileExists(
            atPath: target.appendingPathComponent("iPhoneSync").path
        ))

        let missing = testRoot.appendingPathComponent("missing", isDirectory: true)
        do {
            _ = try DestinationRootResolver.resolve(missing)
            preconditionFailure("Missing destination was accepted")
        } catch DestinationRootError.unavailable {
            // Expected.
        }
    }
}
