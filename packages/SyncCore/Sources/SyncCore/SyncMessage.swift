import Foundation

public enum SessionMessage: Codable, Equatable, Sendable {
    case request(albumID: String, albumName: String, sourceBindingID: String?)
    case accepted(sourceBindingID: String)
    case finished
}

public enum TransferDecision: Codable, Equatable, Sendable {
    case skip
    case start(offset: Int64)
    case resume(offset: Int64)
}

public struct SyncSummary: Codable, Equatable, Sendable {
    public var added: Int
    public var existing: Int
    public var notLocal: Int
    public var failed: Int

    public init(added: Int, existing: Int, notLocal: Int, failed: Int) {
        self.added = added
        self.existing = existing
        self.notLocal = notLocal
        self.failed = failed
    }

    public static let zero = SyncSummary(added: 0, existing: 0, notLocal: 0, failed: 0)
}

public enum TransferFailureCode: String, Codable, Equatable, Sendable {
    case authentication
    case destinationUnavailable
    case diskFull
    case integrity
    case invalidFrame
    case protocolMismatch
    case unknown
}

public enum TransferResult: Codable, Equatable, Sendable {
    case committed(relativePath: String)
    case failed(code: TransferFailureCode, message: String, retryable: Bool)
    case sessionCompleted(SyncSummary)
}

public enum SyncControlMessage: Codable, Equatable, Sendable {
    case session(SessionMessage)
    case offer(ResourceOffer)
    case decision(TransferDecision)
    case result(TransferResult)

    public var frameKind: FrameKind {
        switch self {
        case .session:
            return .session
        case .offer:
            return .offer
        case .decision:
            return .decision
        case .result:
            return .result
        }
    }
}
