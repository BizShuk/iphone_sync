import Foundation
#if canImport(SyncCore) && !VERIFY_STANDALONE
import SyncCore
#else
enum DestinationStorageMode: String, Codable, Equatable, Sendable {
    case albumDate
    case albumOnly
    case flat
}
#endif

struct MacSettingsStore {
    static let setupWindowFrameAutosaveName = "com.shuk.iphonesync.setupWindow"

    private enum Key {
        static let destinationBookmark = "destinationBookmark"
        static let launchAtLoginRequested = "launchAtLoginRequested"
        static let receiverID = "receiverID"
        static let sourceBindingID = "sourceBindingID"
        static let destinationStorageMode = "destinationStorageMode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func receiverID() -> String {
        stableIdentifier(forKey: Key.receiverID)
    }

    func sourceBindingID() -> String {
        stableIdentifier(forKey: Key.sourceBindingID)
    }

    @discardableResult
    func resetSourceBindingID() -> String {
        let value = UUID().uuidString
        defaults.set(value, forKey: Key.sourceBindingID)
        return value
    }

    var destinationBookmark: Data? {
        get { defaults.data(forKey: Key.destinationBookmark) }
        nonmutating set { defaults.set(newValue, forKey: Key.destinationBookmark) }
    }

    var launchAtLoginRequested: Bool {
        get {
            guard defaults.object(forKey: Key.launchAtLoginRequested) != nil else {
                defaults.set(true, forKey: Key.launchAtLoginRequested)
                return true
            }
            return defaults.bool(forKey: Key.launchAtLoginRequested)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.launchAtLoginRequested) }
    }

    var destinationStorageMode: DestinationStorageMode {
        get {
            if let rawValue = defaults.string(forKey: Key.destinationStorageMode) {
                if let mode = DestinationStorageMode(rawValue: rawValue) {
                    return mode
                }
                // Legacy raw value from pre-flat builds; treat as `.flat`.
                if rawValue == "singleFolder" {
                    let migrated: DestinationStorageMode = .flat
                    defaults.set(migrated.rawValue, forKey: Key.destinationStorageMode)
                    return migrated
                }
            }
            let defaultMode: DestinationStorageMode = .albumDate
            defaults.set(defaultMode.rawValue, forKey: Key.destinationStorageMode)
            return defaultMode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.destinationStorageMode)
        }
    }

    private func stableIdentifier(forKey key: String) -> String {
        if let value = defaults.string(forKey: key), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }
}
