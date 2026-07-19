import Foundation
import Testing
@testable import SyncCore

@Test
func controlFrameRoundTrips() throws {
    let requestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let message = SyncControlMessage.session(
        .request(albumID: "album-1", albumName: "Camera", sourceBindingID: nil)
    )
    let frame = try SyncFrame.control(message, requestID: requestID)

    let bytes = try FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeCompleteFrame(bytes)

    #expect(decoded == frame)
    #expect(try decoded.controlMessage() == message)
}

@Test
func oversizedControlPayloadIsRejected() {
    let payload = Data(repeating: 0, count: SyncConstants.maximumControlPayload + 1)

    #expect(throws: FrameCodecError.payloadTooLarge) {
        try SyncFrame(kind: .session, requestID: UUID(), offset: 0, payload: payload)
    }
}

@Test
func chunkLimitIsIndependentFromControlLimit() throws {
    let payload = Data(repeating: 0x5a, count: SyncConstants.chunkSize)
    let frame = try SyncFrame(kind: .chunk, requestID: UUID(), offset: 4_096, payload: payload)

    #expect(try FrameCodec.decodeCompleteFrame(FrameCodec.encode(frame)) == frame)
}

@Test
func malformedMagicIsRejected() throws {
    let frame = try SyncFrame.control(.session(.finished), requestID: UUID())
    var bytes = try FrameCodec.encode(frame)
    bytes[0] = 0

    #expect(throws: FrameCodecError.invalidMagic) {
        try FrameCodec.decodeCompleteFrame(bytes)
    }
}

@Test
func unsupportedProtocolVersionIsRejected() throws {
    let frame = try SyncFrame.control(.session(.finished), requestID: UUID())
    var bytes = try FrameCodec.encode(frame)
    bytes[4] = 0
    bytes[5] = UInt8(SyncConstants.protocolVersion + 1)

    #expect(throws: FrameCodecError.unsupportedVersion(SyncConstants.protocolVersion + 1)) {
        try FrameCodec.decodeCompleteFrame(bytes)
    }
}

@Test
func oversizedChunkIsRejected() {
    #expect(throws: FrameCodecError.payloadTooLarge) {
        try SyncFrame(
            kind: .chunk,
            requestID: UUID(),
            offset: 0,
            payload: Data(repeating: 0, count: SyncConstants.chunkSize + 1)
        )
    }
}

@Test
func truncatedFrameIsRejected() throws {
    let frame = try SyncFrame.control(.session(.finished), requestID: UUID())
    let bytes = try FrameCodec.encode(frame)

    #expect(throws: FrameCodecError.truncatedFrame) {
        try FrameCodec.decodeCompleteFrame(Data(bytes.dropLast()))
    }
}
