import Foundation

public enum FrameKind: UInt8, Codable, Equatable, Sendable {
    case session = 1
    case offer = 2
    case decision = 3
    case chunk = 4
    case result = 5
}

public enum FrameCodecError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidKind(UInt8)
    case invalidHeaderLength
    case payloadTooLarge
    case truncatedFrame
    case trailingBytes
    case controlKindMismatch
}

public struct FrameHeader: Equatable, Sendable {
    public static let byteCount = 40

    public let version: UInt16
    public let kind: FrameKind
    public let requestID: UUID
    public let offset: UInt64
    public let payloadLength: UInt64
}

public struct SyncFrame: Equatable, Sendable {
    public let kind: FrameKind
    public let requestID: UUID
    public let offset: UInt64
    public let payload: Data

    public init(kind: FrameKind, requestID: UUID, offset: UInt64, payload: Data) throws {
        let maximum = kind == .chunk ? SyncConstants.chunkSize : SyncConstants.maximumControlPayload
        guard payload.count <= maximum else {
            throw FrameCodecError.payloadTooLarge
        }
        self.kind = kind
        self.requestID = requestID
        self.offset = offset
        self.payload = payload
    }

    public static func control(_ message: SyncControlMessage, requestID: UUID) throws -> SyncFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        return try SyncFrame(kind: message.frameKind, requestID: requestID, offset: 0, payload: payload)
    }

    public func controlMessage() throws -> SyncControlMessage {
        guard kind != .chunk else {
            throw FrameCodecError.controlKindMismatch
        }
        let message = try JSONDecoder().decode(SyncControlMessage.self, from: payload)
        guard message.frameKind == kind else {
            throw FrameCodecError.controlKindMismatch
        }
        return message
    }
}

public enum FrameCodec {
    private static let magic: [UInt8] = [0x49, 0x50, 0x53, 0x31]

    public static func encode(_ frame: SyncFrame) throws -> Data {
        let validated = try SyncFrame(
            kind: frame.kind,
            requestID: frame.requestID,
            offset: frame.offset,
            payload: frame.payload
        )
        var data = Data()
        data.reserveCapacity(FrameHeader.byteCount + validated.payload.count)
        data.append(contentsOf: magic)
        appendUInt16(SyncConstants.protocolVersion, to: &data)
        data.append(validated.kind.rawValue)
        data.append(0)

        var uuid = validated.requestID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }

        appendUInt64(validated.offset, to: &data)
        appendUInt64(UInt64(validated.payload.count), to: &data)
        data.append(validated.payload)
        return data
    }

    public static func decodeHeader(_ data: Data) throws -> FrameHeader {
        guard data.count == FrameHeader.byteCount else {
            throw FrameCodecError.invalidHeaderLength
        }
        guard Array(data[0..<4]) == magic else {
            throw FrameCodecError.invalidMagic
        }

        let version = readUInt16(data, at: 4)
        guard version == SyncConstants.protocolVersion else {
            throw FrameCodecError.unsupportedVersion(version)
        }
        let rawKind = data[6]
        guard let kind = FrameKind(rawValue: rawKind) else {
            throw FrameCodecError.invalidKind(rawKind)
        }

        let bytes = Array(data[8..<24])
        let requestID = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        let offset = readUInt64(data, at: 24)
        let payloadLength = readUInt64(data, at: 32)
        let maximum = kind == .chunk ? SyncConstants.chunkSize : SyncConstants.maximumControlPayload
        guard payloadLength <= UInt64(maximum) else {
            throw FrameCodecError.payloadTooLarge
        }

        return FrameHeader(
            version: version,
            kind: kind,
            requestID: requestID,
            offset: offset,
            payloadLength: payloadLength
        )
    }

    public static func decodeCompleteFrame(_ data: Data) throws -> SyncFrame {
        guard data.count >= FrameHeader.byteCount else {
            throw FrameCodecError.truncatedFrame
        }
        let headerData = data.prefix(FrameHeader.byteCount)
        let header = try decodeHeader(Data(headerData))
        let expectedCount = FrameHeader.byteCount + Int(header.payloadLength)
        guard data.count >= expectedCount else {
            throw FrameCodecError.truncatedFrame
        }
        guard data.count == expectedCount else {
            throw FrameCodecError.trailingBytes
        }
        return try SyncFrame(
            kind: header.kind,
            requestID: header.requestID,
            offset: header.offset,
            payload: Data(data.dropFirst(FrameHeader.byteCount))
        )
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}
