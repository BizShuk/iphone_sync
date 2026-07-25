// SyncMessage — JSON payload shapes for control frames (session / offer /
// decision / result), mirroring `packages/SyncCore/Sources/SyncCore/SyncMessage.swift`.
// The wire format is `JSONEncoder` with `.sortedKeys` to match the Swift
// canonical ordering.

import { FrameKind } from './frame-codec.js';

// ------- SessionMessage -------
//
// cases:
//   request(albumID, albumName, requestedBindingID?)
//   accepted(bindingID)
//   rejected(reason)
//   finished

export type SessionRequestPayload = {
  albumID: string;
  albumName: string;
  sourceBindingID?: string;
};
export type SessionAcceptedPayload = { sourceBindingID: string };
export type SessionRejectedPayload = { reason: string };
export type SessionFinishedPayload = Record<string, never>;

export type SessionMessage =
  | { kind: 'request'; albumID: string; albumName: string; sourceBindingID?: string }
  | { kind: 'accepted'; sourceBindingID: string }
  | { kind: 'rejected'; reason: string }
  | { kind: 'finished' };

export function encodeSessionRequest(p: SessionRequestPayload): string {
  const out: Record<string, string> = { albumID: p.albumID, albumName: p.albumName };
  if (p.sourceBindingID !== undefined) out.sourceBindingID = p.sourceBindingID;
  return JSON.stringify(out, sortedKeys);
}

export function decodeSessionMessage(payload: Uint8Array): SessionMessage {
  const obj = JSON.parse(new TextDecoder().decode(payload)) as Record<string, unknown>;
  if (typeof obj.albumID === 'string' && typeof obj.albumName === 'string') {
    return {
      kind: 'request',
      albumID: obj.albumID,
      albumName: obj.albumName,
      sourceBindingID: typeof obj.sourceBindingID === 'string' ? obj.sourceBindingID : undefined,
    };
  }
  if (typeof obj.sourceBindingID === 'string' && Object.keys(obj).length === 1) {
    return { kind: 'accepted', sourceBindingID: obj.sourceBindingID };
  }
  if (typeof obj.reason === 'string') {
    return { kind: 'rejected', reason: obj.reason };
  }
  if (Object.keys(obj).length === 0) {
    return { kind: 'finished' };
  }
  throw new Error('SessionMessage: unrecognised payload');
}

// ------- TransferDecision -------

export type TransferDecision =
  | { kind: 'skip' }
  | { kind: 'start'; offset: number }
  | { kind: 'resume'; offset: number };

export function encodeDecision(d: TransferDecision): string {
  if (d.kind === 'skip') return JSON.stringify('skip');
  return JSON.stringify({ offset: d.offset }, sortedKeys);
}

export function decodeDecision(payload: Uint8Array): TransferDecision {
  const obj = JSON.parse(new TextDecoder().decode(payload)) as unknown;
  if (typeof obj === 'string' && obj === 'skip') return { kind: 'skip' };
  if (typeof obj === 'object' && obj !== null && 'offset' in obj) {
    const offset = (obj as { offset: unknown }).offset;
    if (typeof offset !== 'number') throw new Error('Decision.offset must be a number');
    if (offset === 0) return { kind: 'start', offset };
    return { kind: 'resume', offset };
  }
  throw new Error('TransferDecision: unrecognised payload');
}

// ------- SyncSummary + TransferResult -------

export interface SyncSummary {
  added: number;
  existing: number;
  notLocal: number;
  failed: number;
}

export type TransferResult =
  | { kind: 'committed'; relativePath: string }
  | { kind: 'failed'; code: TransferFailureCode; message: string; retryable: boolean }
  | { kind: 'sessionCompleted'; summary: SyncSummary };

export type TransferFailureCode =
  | 'authentication'
  | 'destinationUnavailable'
  | 'diskFull'
  | 'integrity'
  | 'invalidFrame'
  | 'protocolMismatch'
  | 'unknown';

export function encodeResult(r: TransferResult): string {
  if (r.kind === 'committed') {
    return JSON.stringify({ relativePath: r.relativePath }, sortedKeys);
  }
  if (r.kind === 'failed') {
    return JSON.stringify(
      { code: r.code, message: r.message, retryable: r.retryable },
      sortedKeys,
    );
  }
  return JSON.stringify({ summary: r.summary }, sortedKeys);
}

export function decodeResult(payload: Uint8Array): TransferResult {
  const obj = JSON.parse(new TextDecoder().decode(payload)) as Record<string, unknown>;
  if (typeof obj.relativePath === 'string') {
    return { kind: 'committed', relativePath: obj.relativePath };
  }
  if (typeof obj.code === 'string') {
    return {
      kind: 'failed',
      code: obj.code as TransferFailureCode,
      message: typeof obj.message === 'string' ? obj.message : '',
      retryable: Boolean(obj.retryable),
    };
  }
  if (typeof obj.summary === 'object' && obj.summary !== null) {
    const s = obj.summary as Record<string, unknown>;
    return {
      kind: 'sessionCompleted',
      summary: {
        added: numberFrom(s.added),
        existing: numberFrom(s.existing),
        notLocal: numberFrom(s.notLocal),
        failed: numberFrom(s.failed),
      },
    };
  }
  throw new Error('TransferResult: unrecognised payload');
}

function numberFrom(v: unknown): number {
  if (typeof v === 'number') return v;
  if (typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v))) return Number(v);
  throw new Error('expected number');
}

// ------- SyncControlMessage dispatch -------

export type SyncControlMessage =
  | { frameKind: FrameKind.session; message: SessionMessage }
  | { frameKind: FrameKind.decision; message: TransferDecision }
  | { frameKind: FrameKind.result; message: TransferResult };

export function decodeControlMessage(
  kind: FrameKind,
  payload: Uint8Array,
): SyncControlMessage {
  switch (kind) {
    case FrameKind.session:
      return { frameKind: kind, message: decodeSessionMessage(payload) };
    case FrameKind.decision:
      return { frameKind: kind, message: decodeDecision(payload) };
    case FrameKind.result:
      return { frameKind: kind, message: decodeResult(payload) };
    default:
      throw new Error(`SyncControlMessage: kind ${kind} is not a control message`);
  }
}

function sortedKeys(_key: string, value: unknown): unknown {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = (value as Record<string, unknown>)[key];
    }
    return out;
  }
  return value;
}
