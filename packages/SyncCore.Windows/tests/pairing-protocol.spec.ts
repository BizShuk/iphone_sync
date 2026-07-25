import { describe, expect, it } from 'vitest';
import { decodePairingMessage, encodePairingMessage } from '../src/pairing/pairing-protocol';

describe('PairingProtocol', () => {
  it('pairingConfirmationWireMessageContainsProofButNoCode', () => {
    const proof = new Uint8Array(32).fill(0x42);
    const bytes = encodePairingMessage({ kind: 'confirm', proof });
    const text = new TextDecoder().decode(bytes);
    expect(text).toContain('"proof"');
    expect(text).not.toContain('"code"');
    const decoded = decodePairingMessage(bytes);
    expect(decoded.kind).toBe('confirm');
    if (decoded.kind === 'confirm') {
      expect(Array.from(decoded.proof)).toEqual(Array.from(proof));
    }
  });

  it('decodesAcceptedIntoKindAndProof', () => {
    const proof = new Uint8Array(32).fill(0x55);
    const identity = new Uint8Array(32).fill(0x66);
    const bytes = encodePairingMessage({ kind: 'accepted', proof, pskIdentity: identity });
    const decoded = decodePairingMessage(bytes);
    expect(decoded.kind).toBe('accepted');
    if (decoded.kind === 'accepted') {
      expect(Array.from(decoded.proof)).toEqual(Array.from(proof));
      expect(Array.from(decoded.pskIdentity)).toEqual(Array.from(identity));
    }
  });

  it('roundTripsHello', () => {
    const bytes = encodePairingMessage({
      kind: 'hello',
      payload: {
        deviceID: 'device-1',
        displayName: 'My iPhone',
        publicKey: new Uint8Array(32).fill(0x11),
        nonce: new Uint8Array(32).fill(0x22),
      },
    });
    const decoded = decodePairingMessage(bytes);
    expect(decoded.kind).toBe('hello');
    if (decoded.kind === 'hello') {
      expect(decoded.payload.deviceID).toBe('device-1');
      expect(decoded.payload.displayName).toBe('My iPhone');
      expect(Array.from(decoded.payload.publicKey)).toEqual(Array.from(new Uint8Array(32).fill(0x11)));
      expect(Array.from(decoded.payload.nonce)).toEqual(Array.from(new Uint8Array(32).fill(0x22)));
    }
  });

  it('rejectsOversizedPayload', () => {
    const oversize = new Uint8Array(70_000).fill(0x99);
    expect(() => encodePairingMessage({ kind: 'confirm', proof: oversize })).toThrowError(
      /maximumControlPayload/,
    );
  });
});
