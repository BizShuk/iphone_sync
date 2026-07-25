import { describe, expect, it } from 'vitest';
import {
  FrameCodec,
  FrameKind,
  FRAME_HEADER_LENGTH,
  SyncConstants,
} from '../../src/protocol';

/**
 * Codec-only round-trip test. The full Net/TLS-PSK loopback is exercised
 * by `tls-psk.spec.ts` (Phase 3) and by the end-to-end interop test on
 * real hardware (Phase 8). This keeps the layered tests small and fast.
 */
describe('FramedConnection header round-trip', () => {
  it('roundTripsAHeader', () => {
    const requestID = FrameCodec.newRequestID();
    const payload = new TextEncoder().encode('hello');
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
    expect(header.kind).toBe(FrameKind.session);
    expect(Array.from(header.requestID)).toEqual(Array.from(requestID));
    expect(header.payloadLength).toBe(BigInt(payload.length));

    // Decode payload via slicing — verifies the wire layout end-to-end
    // without needing a TCP socket pair.
    const got = new TextDecoder().decode(bytes.subarray(FRAME_HEADER_LENGTH));
    expect(got).toBe('hello');
  });

  it('usesProtocolVersion', () => {
    expect(SyncConstants.protocolVersion).toBe(1);
  });
});
