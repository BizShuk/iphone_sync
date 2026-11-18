import Foundation

struct PhotoAlbum: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
}

/// One paired computer (Mac or Windows) and the albums this iPhone sends to it.
///
/// The PSK lives in the Keychain under `peerAccount`; this record only holds
/// what the UI and the deletion policy need, so it is safe in `UserDefaults`.
struct ReceiverProfile: Codable, Equatable, Identifiable, Sendable {
    /// The receiver's own `receiverID`, advertised in its Bonjour TXT record.
    let id: String
    var displayName: String
    var albums: [PhotoAlbum]
    let pairedAt: Date
    /// Last time the receiver accepted a session. Shown to the user.
    var lastConnectedAt: Date?
    /// Last time every selected album finished on this receiver. Drives the
    /// staleness rule of `DeletionEligibilityPolicy`.
    var lastCompletedAt: Date?

    var peerAccount: String {
        ReceiverProfileStore.peerAccount(receiverID: id)
    }
}

/// A receiver together with its albums filtered against the live Photos
/// library, which is what one run actually syncs.
struct ReceiverSyncPlan: Equatable, Sendable {
    let profile: ReceiverProfile
    let albums: [PhotoAlbum]
}

struct ReceiverProfileStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(
        key: String = "receiverProfiles",
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.key = key
    }

    static func peerAccount(receiverID: String) -> String {
        "paired-peer.\(receiverID)"
    }

    func load() -> [ReceiverProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode(
                  [ReceiverProfile].self,
                  from: data
              ) else {
            return []
        }
        return profiles.sorted { $0.pairedAt < $1.pairedAt }
    }

    func profile(id: String) -> ReceiverProfile? {
        load().first { $0.id == id }
    }

    /// Adds a newly paired receiver, or refreshes the name of one paired
    /// again while keeping its album selection and history.
    @discardableResult
    func upsertPaired(
        id: String,
        displayName: String,
        at date: Date
    ) -> ReceiverProfile {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].displayName = displayName
            save(profiles)
            return profiles[index]
        }
        let profile = ReceiverProfile(
            id: id,
            displayName: displayName,
            albums: [],
            pairedAt: date,
            lastConnectedAt: nil,
            lastCompletedAt: nil
        )
        profiles.append(profile)
        save(profiles)
        return profile
    }

    func setAlbums(_ albums: [PhotoAlbum], receiverID: String) {
        var seen: Set<String> = []
        let unique = albums.filter { seen.insert($0.id).inserted }
        update(receiverID) { $0.albums = unique }
    }

    func markConnected(receiverID: String, at date: Date) {
        update(receiverID) { $0.lastConnectedAt = date }
    }

    func markCompleted(receiverID: String, at date: Date) {
        update(receiverID) {
            $0.lastConnectedAt = date
            $0.lastCompletedAt = date
        }
    }

    func remove(receiverID: String) {
        save(load().filter { $0.id != receiverID })
    }

    private func update(
        _ receiverID: String,
        _ change: (inout ReceiverProfile) -> Void
    ) {
        var profiles = load()
        guard let index = profiles.firstIndex(where: { $0.id == receiverID }) else {
            return
        }
        change(&profiles[index])
        save(profiles)
    }

    private func save(_ profiles: [ReceiverProfile]) {
        guard !profiles.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(profiles), forKey: key)
    }
}
