// PairingProtocol — wire format for the `_iphonesync-pair._tcp` channel.
//
// Layout matches `packages/SyncCore/Sources/SyncCore/PairingProtocol.swift`:
//   [u32 BE length][JSON payload]
//
// JSON schemas:
//   Hello            { deviceID, displayName, publicKey, nonce }
//   Confirm          { proof }
//   Accepted         { proof, pskIdentity }
//   Rejected         { reason }

import { SyncConstants } from '../protocol/constants.js';

export class PairingProtocolError extends Error {
  constructor(
    message: string,
    public readonly code: 'oversized' | 'truncated' | 'invalidJson' | 'invalidMessage',
  ) {
    super(message);
    this.name = 'PairingProtocolError';
  }
}

export interface PairingHello {
  deviceID: string;
  displayName: string;
  publicKey: Uint8Array;
  nonce: Uint8Array;
}

export type PairingMessage =
  | { kind: 'hello'; payload: PairingHello }
  | { kind: 'confirm'; proof: Uint8Array }
  | { kind: 'accepted'; proof: Uint8Array; pskIdentity: Uint8Array }
  | { kind: 'rejected'; reason: string };

export function encodePairingMessage(msg: PairingMessage): Uint8Array {
  let body: string;
  switch (msg.kind) {
    case 'hello': {
      const obj = {
        deviceID: msg.payload.deviceID,
        displayName: msg.payload.displayName,
        publicKey: bytesToHex(msg.payload.publicKey),
        nonce: bytesToHex(msg.payload.nonce),
      };
      body = JSON.stringify(obj, sortedKeys);
      break;
    }
    case 'confirm':
      body = JSON.stringify({ proof: bytesToHex(msg.proof) }, sortedKeys);
      break;
    case 'accepted':
      body = JSON.stringify(
        { proof: bytesToHex(msg.proof), pskIdentity: bytesToHex(msg.pskIdentity) },
        sortedKeys,
      );
      break;
    case 'rejected':
      body = JSON.stringify({ reason: msg.reason }, sortedKeys);
      break;
  }
  const bodyBytes = Buffer.from(body, 'utf-8');
  if (bodyBytes.length > SyncConstants.maximumControlPayload) {
    throw new PairingProtocolError(
      `pairing payload ${bodyBytes.length} > maximumControlPayload`,
      'oversized',
    );
  }
  const frame = Buffer.alloc(4 + bodyBytes.length);
  frame.writeUInt32BE(bodyBytes.length, 0);
  bodyBytes.copy(frame, 4);
  return new Uint8Array(frame);
}

export function decodePairingMessage(buffer: Uint8Array): PairingMessage {
  if (buffer.length < 4) {
    throw new PairingProtocolError('frame too short', 'truncated');
  }
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  const length = view.getUint32(0, false);
  if (length > SyncConstants.maximumControlPayload) {
    throw new PairingProtocolError(
      `payload length ${length} > maximumControlPayload`,
      'oversized',
    );
  }
  if (buffer.length < 4 + length) {
    throw new PairingProtocolError('frame truncated', 'truncated');
  }
  const body = new TextDecoder().decode(buffer.subarray(4, 4 + length));
  let obj: unknown;
  try {
    obj = JSON.parse(body);
  } catch {
    throw new PairingProtocolError('invalid JSON', 'invalidJson');
  }
  if (typeof obj !== 'object' || obj === null) {
    throw new PairingProtocolError('expected JSON object', 'invalidMessage');
  }
  const record = obj as Record<string, unknown>;
  if (typeof record.deviceID === 'string'
      && typeof record.displayName === 'string'
      && typeof record.publicKey === 'string'
      && typeof record.nonce === 'string') {
    return {
      kind: 'hello',
      payload: {
        deviceID: record.deviceID,
        displayName: record.displayName,
        publicKey: hexToBytes(record.publicKey),
        nonce: hexToBytes(record.nonce),
      },
    };
  }
  if (typeof record.proof === 'string' && record.pskIdentity === undefined) {
    return { kind: 'confirm', proof: hexToBytes(record.proof) };
  }
  if (typeof record.proof === 'string' && typeof record.pskIdentity === 'string') {
    return {
      kind: 'accepted',
      proof: hexToBytes(record.proof),
      pskIdentity: hexToBytes(record.pskIdentity),
    };
  }
  if (typeof record.reason === 'string') {
    return { kind: 'rejected', reason: record.reason };
  }
  throw new PairingProtocolError('unrecognised payload', 'invalidMessage');
}

function bytesToHex(b: Uint8Array): string {
  return Buffer.from(b).toString('hex');
}

function hexToBytes(s: string): Uint8Array {
  if (s.length % 2 !== 0) throw new Error('hex string must have even length');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function sortedKeys(_key: string, value: unknown): unknown {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const obj = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(obj).sort()) {
      out[key] = obj[key];
    }
    return out;
  }
  return value;
}
