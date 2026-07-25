import { describe, expect, it } from 'vitest';
import {
  FrameCodec,
  FrameCodecError,
  FRAME_HEADER_LENGTH,
  FRAME_MAGIC,
  FrameKind,
  SyncConstants,
} from '../src/protocol';

describe('FrameCodec', () => {
  it('controlFrameRoundTrips', () => {
    const requestID = FrameCodec.newRequestID();
    const payload = new Uint8Array([0x7b, 0x22, 0x69, 0x64, 0x22, 0x3a, 0x31, 0x7d]); // {"id":1}
    const bytes = FrameCodec.encode(
      {
        version: SyncConstants.protocolVersion,
        kind: FrameKind.session,
        reserved: 0,
        requestID,
        offset: 0n,
        payloadLength: BigInt(payload.length),
      },
      payload,
    );
    expect(bytes.length).toBe(FRAME_HEADER_LENGTH + payload.length);
    const header = FrameCodec.decodeHeader(bytes.subarray(0, FRAME_HEADER_LENGTH));
    expect(header.version).toBe(SyncConstants.protocolVersion);
    expect(header.kind).toBe(FrameKind.session);
    expect(header.reserved).toBe(0);
    expect(Array.from(header.requestID)).toEqual(Array.from(requestID));
    expect(header.offset).toBe(0n);
    expect(header.payloadLength).toBe(BigInt(payload.length));
  });

  it('oversizedControlPayloadIsRejected', () => {
    const requestID = FrameCodec.newRequestID();
    const oversize = new Uint8Array(SyncConstants.maximumControlPayload + 1);
    expect(() =>
      FrameCodec.encode(
        {
          version: SyncConstants.protocolVersion,
          kind: FrameKind.session,
          reserved: 0,
          requestID,
          offset: 0n,
          payloadLength: BigInt(oversize.length),
        },
        oversize,
      ),
    ).toThrowError(FrameCodecError);
  });

  it('chunkLimitIsIndependentFromControlLimit', () => {
    const requestID = FrameCodec.newRequestID();
    const bigChunk = new Uint8Array(SyncConstants.chunkSize);
    const bytes = FrameCodec.encode(
      {
        version: SyncConstants.protocolVersion,
        kind: FrameKind.chunk,
        reserved: 0,
        requestID,
        offset: 0n,
        payloadLength: BigInt(bigChunk.length),
      },
      bigChunk,
    );
    expect(bytes.length).toBe(FRAME_HEADER_LENGTH + bigChunk.length);
  });

  it('malformedMagicIsRejected', () => {
    const tampered = new Uint8Array(FRAME_HEADER_LENGTH);
    tampered.set(FRAME_MAGIC, 0);
    tampered[0] = 0x00;
    expect(() => FrameCodec.decodeHeader(tampered)).toThrowError(/invalid magic/);
  });

  it('unsupportedProtocolVersionIsRejected', () => {
    const tampered = new Uint8Array(FRAME_HEADER_LENGTH);
    tampered.set(FRAME_MAGIC, 0);
    const view = new DataView(tampered.buffer);
    view.setUint16(4, SyncConstants.protocolVersion + 1, false);
    expect(() => FrameCodec.decodeHeader(tampered)).toThrowError(/unsupported/);
  });

  it('oversizedChunkIsRejected', () => {
    const requestID = FrameCodec.newRequestID();
    const tooBig = new Uint8Array(SyncConstants.chunkSize + 1);
    expect(() =>
      FrameCodec.encode(
        {
          version: SyncConstants.protocolVersion,
          kind: FrameKind.chunk,
          reserved: 0,
          requestID,
          offset: 0n,
          payloadLength: BigInt(tooBig.length),
        },
        tooBig,
      ),
    ).toThrowError(/exceeds chunkSize/);
  });

  it('truncatedFrameIsRejected', () => {
    expect(() => FrameCodec.decodeHeader(new Uint8Array(FRAME_HEADER_LENGTH - 1))).toThrowError(
      /truncated header/,
    );
  });
});
