// FrameCodec — 40-byte big-endian header + payload, mirroring
// `packages/SyncCore/Sources/SyncCore/FrameCodec.swift`.
//
// Header layout (offset, bytes, field):
//   0   4   magic           ASCII "IPS1" = 0x49 0x50 0x53 0x31
//   4   2   version         u16 BE, must equal SyncConstants.protocolVersion
//   6   1   kind            u8  (FrameKind rawValue)
//   7   1   reserved        u8  (must be 0)
//   8  16   requestID       raw UUID bytes
//  24   8   offset          u64 BE
//  32   8   payloadLength   u64 BE
//  40   N   payload

import { randomUUID } from 'node:crypto';
import { SyncConstants } from './constants.js';

export const FRAME_MAGIC = Uint8Array.from([0x49, 0x50, 0x53, 0x31]); // "IPS1"
export const FRAME_HEADER_LENGTH = 40;

export enum FrameKind {
  session = 1,
  offer = 2,
  decision = 3,
  chunk = 4,
  result = 5,
}

export interface FrameHeader {
  version: number;
  kind: FrameKind;
  reserved: number;
  requestID: Uint8Array; // 16 bytes
  offset: bigint;
  payloadLength: bigint;
}

export class FrameCodecError extends Error {
  constructor(
    message: string,
    public readonly code:
      | 'invalidMagic'
      | 'unsupportedVersion'
      | 'payloadTooLarge'
      | 'truncatedFrame'
      | 'invalidHeaderLength'
      | 'invalidKind',
  ) {
    super(message);
    this.name = 'FrameCodecError';
  }
}

export class FrameCodec {
  /** Encode a header + payload into a single `Uint8Array`. */
  static encode(header: FrameHeader, payload: Uint8Array): Uint8Array {
    if (payload.length > Number.MAX_SAFE_INTEGER) {
      throw new RangeError('payload too large to encode');
    }
    const payloadLength = BigInt(payload.length);
    if (header.kind === FrameKind.chunk) {
      if (payloadLength > BigInt(SyncConstants.chunkSize)) {
        throw new FrameCodecError(
          `chunk payload ${payloadLength} exceeds chunkSize ${SyncConstants.chunkSize}`,
          'payloadTooLarge',
        );
      }
    } else if (payloadLength > BigInt(SyncConstants.maximumControlPayload)) {
      throw new FrameCodecError(
        `control payload ${payloadLength} exceeds maximumControlPayload ${SyncConstants.maximumControlPayload}`,
        'payloadTooLarge',
      );
    }
    if (header.requestID.length !== 16) {
      throw new FrameCodecError('requestID must be 16 bytes', 'invalidHeaderLength');
    }
    const out = new Uint8Array(FRAME_HEADER_LENGTH + payload.length);
    out.set(FRAME_MAGIC, 0);
    const view = new DataView(out.buffer);
    view.setUint16(4, header.version, false);
    view.setUint8(6, header.kind);
    view.setUint8(7, header.reserved);
    out.set(header.requestID, 8);
    view.setBigUint64(24, header.offset, false);
    view.setBigUint64(32, payloadLength, false);
    out.set(payload, FRAME_HEADER_LENGTH);
    return out;
  }

  /** Decode a header from a 40-byte buffer. */
  static decodeHeader(buffer: Uint8Array): FrameHeader {
    if (buffer.length < FRAME_HEADER_LENGTH) {
      throw new FrameCodecError(
        `truncated header: ${buffer.length} bytes`,
        'truncatedFrame',
      );
    }
    for (let i = 0; i < 4; i++) {
      if (buffer[i] !== FRAME_MAGIC[i]) {
        throw new FrameCodecError('invalid magic', 'invalidMagic');
      }
    }
    const view = new DataView(buffer.buffer, buffer.byteOffset, FRAME_HEADER_LENGTH);
    const version = view.getUint16(4, false);
    if (version !== SyncConstants.protocolVersion) {
      throw new FrameCodecError(
        `unsupported protocol version ${version}`,
        'unsupportedVersion',
      );
    }
    const kind = view.getUint8(6);
    if (!(kind in FrameKind)) {
      throw new FrameCodecError(`invalid frame kind ${kind}`, 'invalidKind');
    }
    const reserved = view.getUint8(7);
    const requestID = buffer.slice(8, 24);
    const offset = view.getBigUint64(24, false);
    const payloadLength = view.getBigUint64(32, false);
    return {
      version,
      kind: kind as FrameKind,
      reserved,
      requestID,
      offset,
      payloadLength,
    };
  }

  static newRequestID(): Uint8Array {
    // RFC 4122 random UUID; raw 16 bytes match Swift's `UUID().uuid`.
    const hex = randomUUID().replace(/-/g, '');
    const out = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }
    return out;
  }
}
