// FramedConnection — wraps a Node `net.Socket` (already wrapped in TLS by
// `TlsPskServer`) and provides byte-oriented `send(SyncFrame)` /
// `receive()` over the 40-byte FrameCodec header. Mirrors
// `packages/SyncCore/Sources/SyncCore/FramedConnection.swift`.

import type { Socket } from 'node:net';
import { FrameCodec, FRAME_HEADER_LENGTH, FrameKind, type FrameHeader } from './frame-codec.js';
import { SyncConstants } from './constants.js';

export class FramedConnectionError extends Error {
  constructor(message: string, public readonly code: 'truncatedFrame' | 'closed') {
    super(message);
    this.name = 'FramedConnectionError';
  }
}

export interface SyncFrame {
  kind: FrameKind;
  requestID: Uint8Array;
  offset: bigint;
  payload: Uint8Array;
}

export class FramedConnection {
  constructor(private readonly socket: Socket) {}

  /** Send a fully-typed frame. The header is built automatically. */
  async send(frame: SyncFrame): Promise<void> {
    if (frame.payload.length > Number.MAX_SAFE_INTEGER) {
      throw new RangeError('payload too large');
    }
    const header = {
      version: SyncConstants.protocolVersion,
      kind: frame.kind,
      reserved: 0,
      requestID: frame.requestID,
      offset: frame.offset,
      payloadLength: BigInt(frame.payload.length),
    };
    const bytes = FrameCodec.encode(header, frame.payload);
    await this.writeAll(bytes);
  }

  /** Receive a single frame. */
  async receive(): Promise<{ header: FrameHeader; payload: Uint8Array }> {
    const headerBuf = await this.readExactly(FRAME_HEADER_LENGTH);
    const header = FrameCodec.decodeHeader(headerBuf);
    const payloadLength = Number(header.payloadLength);
    if (payloadLength > SyncConstants.chunkSize && header.kind === FrameKind.chunk) {
      throw new FramedConnectionError(
        `chunk payload ${payloadLength} exceeds chunkSize`,
        'truncatedFrame',
      );
    }
    if (payloadLength > SyncConstants.maximumControlPayload && header.kind !== FrameKind.chunk) {
      throw new FramedConnectionError(
        `control payload ${payloadLength} exceeds maximumControlPayload`,
        'truncatedFrame',
      );
    }
    const payload = await this.readExactly(payloadLength);
    return { header, payload };
  }

  destroy(): void {
    this.socket.destroy();
  }

  private async writeAll(bytes: Uint8Array): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.socket.write(bytes, (err) => (err ? reject(err) : resolve()));
    });
  }

  private async readExactly(length: number): Promise<Uint8Array> {
    if (length === 0) return new Uint8Array(0);
    return await new Promise<Uint8Array>((resolve, reject) => {
      const chunks: Buffer[] = [];
      let received = 0;
      const onData = (chunk: Buffer): void => {
        const remaining = length - received;
        if (chunk.length >= remaining) {
          chunks.push(chunk.subarray(0, remaining));
          received += remaining;
          this.socket.off('data', onData);
          this.socket.off('error', onError);
          this.socket.off('close', onClose);
          resolve(Buffer.concat(chunks));
          return;
        }
        chunks.push(chunk);
        received += chunk.length;
      };
      const onError = (err: Error): void => {
        this.socket.off('data', onData);
        this.socket.off('close', onClose);
        reject(err);
      };
      const onClose = (): void => {
        this.socket.off('data', onData);
        this.socket.off('error', onError);
        reject(new FramedConnectionError('connection closed mid-read', 'closed'));
      };
      this.socket.on('data', onData);
      this.socket.once('error', onError);
      this.socket.once('close', onClose);
    });
  }
}
