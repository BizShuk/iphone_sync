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
