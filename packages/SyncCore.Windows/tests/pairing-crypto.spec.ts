import { describe, expect, it } from 'vitest';
import { PairingCrypto } from '../src/crypto';
import { SyncConstants } from '../src/protocol';

describe('PairingCrypto', () => {
  it('bothSidesDeriveSameCodePSKAndProofs', () => {
    const initiator = PairingCrypto.makeMaterial();
    const receiver = PairingCrypto.makeMaterial();

    const sharedSecretInitiator = PairingCrypto.sharedSecretWith(
      initiator.privateKeyObject,
      receiver.publicKey,
    );
    const sharedSecretReceiver = PairingCrypto.sharedSecretWith(
      receiver.privateKeyObject,
      initiator.publicKey,
    );
    expect(Array.from(sharedSecretInitiator)).toEqual(Array.from(sharedSecretReceiver));

    const transcript = PairingCrypto.transcriptHash({
      protocolVersion: SyncConstants.protocolVersion,
      receiverID: 'mac-abc-123',
      initiatorPublicKey: initiator.publicKey,
      receiverPublicKey: receiver.publicKey,
      initiatorNonce: initiator.nonce,
      receiverNonce: receiver.nonce,
    });
    const derivedInitiator = PairingCrypto.derive(sharedSecretInitiator, transcript);
    const derivedReceiver = PairingCrypto.derive(sharedSecretReceiver, transcript);

    expect(derivedInitiator.verificationCode).toBe(derivedReceiver.verificationCode);
    expect(derivedInitiator.verificationCode).toMatch(/^\d{6}$/);
    expect(Array.from(derivedInitiator.psk)).toEqual(Array.from(derivedReceiver.psk));
    expect(Array.from(derivedInitiator.pskIdentity)).toEqual(
      Array.from(derivedReceiver.pskIdentity),
    );
    expect(Array.from(derivedInitiator.clientProof)).toEqual(
      Array.from(derivedReceiver.clientProof),
    );
    expect(Array.from(derivedInitiator.serverProof)).toEqual(
      Array.from(derivedReceiver.serverProof),
    );
  });

  it('transcriptTamperingChangesDerivedSecret', () => {
    const initiator = PairingCrypto.makeMaterial();
    const receiver = PairingCrypto.makeMaterial();
    const sharedSecret = PairingCrypto.sharedSecretWith(
      initiator.privateKeyObject,
      receiver.publicKey,
    );

    const transcript = PairingCrypto.transcriptHash({
      protocolVersion: SyncConstants.protocolVersion,
      receiverID: 'mac-abc-123',
      initiatorPublicKey: initiator.publicKey,
      receiverPublicKey: receiver.publicKey,
      initiatorNonce: initiator.nonce,
      receiverNonce: receiver.nonce,
    });
    const derived = PairingCrypto.derive(sharedSecret, transcript);

    const tamperedTranscript = PairingCrypto.transcriptHash({
      protocolVersion: SyncConstants.protocolVersion,
      receiverID: 'other-mac',
      initiatorPublicKey: initiator.publicKey,
      receiverPublicKey: receiver.publicKey,
      initiatorNonce: initiator.nonce,
      receiverNonce: receiver.nonce,
    });
    const derivedTampered = PairingCrypto.derive(sharedSecret, tamperedTranscript);

    expect(Array.from(derived.psk)).not.toEqual(Array.from(derivedTampered.psk));
    expect(Array.from(derived.clientProof)).not.toEqual(
      Array.from(derivedTampered.clientProof),
    );
  });

  it('generatesSixDigitCode', () => {
    const material = PairingCrypto.makeMaterial();
    expect(material.publicKey.length).toBe(32);
    expect(material.privateKey.length).toBe(32);
    expect(material.nonce.length).toBe(32);
  });
});
