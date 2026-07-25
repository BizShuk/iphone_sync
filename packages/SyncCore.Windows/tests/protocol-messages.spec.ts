import { describe, expect, it } from 'vitest';
import {
  decodeDecision,
  decodeResult,
  decodeSessionMessage,
  encodeDecision,
  encodeResult,
  encodeSessionRequest,
  FrameKind,
  SyncConstants,
} from '../src/protocol';

describe('SyncMessage', () => {
  it('roundTripsSessionRequest', () => {
    const json = encodeSessionRequest({
      albumID: 'A1',
      albumName: 'Trip',
      sourceBindingID: 'binding-1',
    });
    const bytes = new TextEncoder().encode(json);
    const decoded = decodeSessionMessage(bytes);
    expect(decoded).toEqual({
      kind: 'request',
      albumID: 'A1',
      albumName: 'Trip',
      sourceBindingID: 'binding-1',
    });
  });

  it('decodesSessionAccepted', () => {
    const json = JSON.stringify({ sourceBindingID: 'binding-1' });
    const decoded = decodeSessionMessage(new TextEncoder().encode(json));
    expect(decoded).toEqual({ kind: 'accepted', sourceBindingID: 'binding-1' });
  });

  it('decodesSkipDecision', () => {
    const json = encodeDecision({ kind: 'skip' });
    expect(json).toBe(JSON.stringify('skip'));
    const decoded = decodeDecision(new TextEncoder().encode(json));
    expect(decoded.kind).toBe('skip');
  });

  it('decodesStartDecision', () => {
    const decoded = decodeDecision(
      new TextEncoder().encode(JSON.stringify({ offset: 0 })),
    );
    expect(decoded).toEqual({ kind: 'start', offset: 0 });
  });

  it('decodesResumeDecision', () => {
    const decoded = decodeDecision(
      new TextEncoder().encode(JSON.stringify({ offset: 1024 })),
    );
    expect(decoded).toEqual({ kind: 'resume', offset: 1024 });
  });

  it('roundTripsResultCommitted', () => {
    const json = encodeResult({ kind: 'committed', relativePath: 'iPhoneSync/A/2026/07/x.jpg' });
    const decoded = decodeResult(new TextEncoder().encode(json));
    expect(decoded.kind).toBe('committed');
    if (decoded.kind === 'committed') {
      expect(decoded.relativePath).toBe('iPhoneSync/A/2026/07/x.jpg');
    }
  });

  it('roundTripsResultFailed', () => {
    const json = encodeResult({
      kind: 'failed',
      code: 'integrity',
      message: 'sha mismatch',
      retryable: true,
    });
    const decoded = decodeResult(new TextEncoder().encode(json));
    expect(decoded.kind).toBe('failed');
    if (decoded.kind === 'failed') {
      expect(decoded.code).toBe('integrity');
      expect(decoded.retryable).toBe(true);
    }
  });

  it('roundTripsResultSessionCompleted', () => {
    const json = encodeResult({
      kind: 'sessionCompleted',
      summary: { added: 1, existing: 2, notLocal: 0, failed: 0 },
    });
    const decoded = decodeResult(new TextEncoder().encode(json));
    expect(decoded.kind).toBe('sessionCompleted');
    if (decoded.kind === 'sessionCompleted') {
      expect(decoded.summary).toEqual({ added: 1, existing: 2, notLocal: 0, failed: 0 });
    }
  });

  it('exposesProtocolVersion', () => {
    expect(SyncConstants.protocolVersion).toBe(1);
  });
});
