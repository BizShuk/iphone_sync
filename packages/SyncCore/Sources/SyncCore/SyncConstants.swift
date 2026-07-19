import Foundation

public enum SyncConstants {
    public static let protocolVersion: UInt16 = 1
    public static let normalServiceType = "_iphonesync._tcp"
    public static let pairingServiceType = "_iphonesync-pair._tcp"
    public static let chunkSize = 1_048_576
    public static let checkpointSize: Int64 = 16_777_216
    public static let maximumControlPayload = 65_536
}
