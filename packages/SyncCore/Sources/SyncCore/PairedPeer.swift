import Foundation

public struct PairedPeer: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let pskIdentity: Data
    public let psk: Data
    public let sourceBindingID: String?

    public init(
        id: String,
        displayName: String,
        pskIdentity: Data,
        psk: Data,
        sourceBindingID: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.pskIdentity = pskIdentity
        self.psk = psk
        self.sourceBindingID = sourceBindingID
    }
}
