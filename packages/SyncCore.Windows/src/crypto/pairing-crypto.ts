// PairingCrypto — mirrors `packages/SyncCore/Sources/SyncCore/PairingCrypto.swift`.
//
// Curve25519 ephemeral key agreement + SHA-256 transcript hash + HKDF-SHA256
// derivation of SAS / PSK / identity / clientProof / serverProof.
//
// Transcript hash canonical form (length-prefixed):
//   u16 BE protocolVersion
//   u32 BE length, receiverID.utf8
//   u32 BE length, initiatorPublicKey
//   u32 BE length, receiverPublicKey
//   u32 BE length, initiatorNonce
//   u32 BE length, receiverNonce
//
// HKDF salt = transcriptHash (32 bytes).
// HKDF info = label (e.g. "iphonesync-sas-v1").
// Out lengths: SAS = 3 bytes, others = 32 bytes.

import {
  createHash,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  type KeyObject,
} from 'node:crypto';
import { SyncConstants } from '../protocol/constants.js';

export interface PairingMaterial {
  /** 32-byte Curve25519 public key (raw). */
  publicKey: Uint8Array;
  /** 32-byte Curve25519 private key (raw). */
  privateKey: Uint8Array;
  /** 32-byte random nonce. */
  nonce: Uint8Array;
  /** Cached KeyObject view for `sharedSecret()`. */
  privateKeyObject: KeyObject;
}

export interface PairingDerivedSecrets {
  verificationCode: string;
  psk: Uint8Array;
  pskIdentity: Uint8Array;
  clientProof: Uint8Array;
  serverProof: Uint8Array;
}

export interface PairingTranscriptInput {
  protocolVersion: number;
  receiverID: string;
  initiatorPublicKey: Uint8Array;
  receiverPublicKey: Uint8Array;
  initiatorNonce: Uint8Array;
  receiverNonce: Uint8Array;
}

export class PairingCrypto {
  static readonly SAS_BYTE_LENGTH = 3;
  static readonly PROOF_BYTE_LENGTH = 32;
  static readonly NONCE_BYTE_LENGTH = 32;

  /** Generate a fresh ephemeral keypair + nonce. */
  static makeMaterial(): PairingMaterial {
    const { publicKey: pubKeyObj, privateKey: privKeyObj } = generateKeyPairSync('x25519');
    const publicKey = readRawX25519PublicKey(pubKeyObj);
    const privateKey = readRawX25519PrivateKey(privKeyObj);
    const nonce = new Uint8Array(randomBytes(PairingCrypto.NONCE_BYTE_LENGTH));
    return { publicKey, privateKey, nonce, privateKeyObject: privKeyObj };
  }

  /** Compute shared secret from this side's KeyObject + peer's raw public key. */
  static sharedSecretWith(
    selfPrivateKey: KeyObject,
    peerPublicKey: Uint8Array,
  ): Uint8Array {
    const peerPubKeyObj = buildPublicKeyObject(peerPublicKey);
    const shared = diffieHellman({
      privateKey: selfPrivateKey,
      publicKey: peerPubKeyObj,
    });
    return new Uint8Array(shared);
  }

  static transcriptHash(input: PairingTranscriptInput): Uint8Array {
    if (input.protocolVersion !== SyncConstants.protocolVersion) {
      throw new Error(
        `transcriptHash: protocolVersion ${input.protocolVersion} differs from SyncConstants.protocolVersion ${SyncConstants.protocolVersion}`,
      );
    }
    if (input.initiatorNonce.length !== PairingCrypto.NONCE_BYTE_LENGTH) {
      throw new Error(`initiatorNonce must be ${PairingCrypto.NONCE_BYTE_LENGTH} bytes`);
    }
    if (input.receiverNonce.length !== PairingCrypto.NONCE_BYTE_LENGTH) {
      throw new Error(`receiverNonce must be ${PairingCrypto.NONCE_BYTE_LENGTH} bytes`);
    }
    const chunks: Buffer[] = [];
    const versionBuf = Buffer.alloc(2);
    versionBuf.writeUInt16BE(input.protocolVersion, 0);
    chunks.push(versionBuf);
    const idBuf = Buffer.from(input.receiverID, 'utf-8');
    chunks.push(u32Length(idBuf.length));
    chunks.push(idBuf);
    pushLengthPrefixed(chunks, input.initiatorPublicKey);
    pushLengthPrefixed(chunks, input.receiverPublicKey);
    pushLengthPrefixed(chunks, input.initiatorNonce);
    pushLengthPrefixed(chunks, input.receiverNonce);
    const hash = createHash('sha256').update(Buffer.concat(chunks)).digest();
    return new Uint8Array(hash);
  }

  static derive(
    sharedSecret: Uint8Array,
    transcriptHash: Uint8Array,
  ): PairingDerivedSecrets {
    const labels = SyncConstants.hkdfLabels;
    const psk = deriveBytes(sharedSecret, transcriptHash, labels.psk, 32);
    const identity = deriveBytes(sharedSecret, transcriptHash, labels.identity, 32);
    const clientProof = deriveBytes(sharedSecret, transcriptHash, labels.clientProof, 32);
    const serverProof = deriveBytes(sharedSecret, transcriptHash, labels.serverProof, 32);
    const sasBytes = deriveBytes(sharedSecret, transcriptHash, labels.sas, PairingCrypto.SAS_BYTE_LENGTH);
    return {
      verificationCode: PairingCrypto.formatVerificationCode(sasBytes),
      psk,
      pskIdentity: identity,
      clientProof,
      serverProof,
    };
  }

  static formatVerificationCode(bytes: Uint8Array): string {
    if (bytes.length < PairingCrypto.SAS_BYTE_LENGTH) {
      throw new Error(`SAS bytes must be at least ${PairingCrypto.SAS_BYTE_LENGTH} bytes`);
    }
    const v =
      ((bytes[0]! << 12) | (bytes[1]! << 4) | (bytes[2]! >> 4)) % 1_000_000;
    return String(v).padStart(6, '0');
  }

  static constantTimeEquals(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;
    let acc = 0;
    for (let i = 0; i < a.length; i++) {
      acc |= (a[i]! ^ b[i]!);
    }
    return acc === 0;
  }
}

// X25519 has 32-byte raw keys; the KeyObject API only exposes JWK on raw
// X25519 keys, so we round-trip through the JWK `x` (public) / `d` (private)
// fields. Both are 32-byte big-endian values after base64url decoding.
function readRawX25519PublicKey(obj: KeyObject): Uint8Array {
  const jwk = obj.export({ format: 'jwk' }) as { x?: string };
  if (!jwk.x) throw new Error('X25519 public key has no JWK x field');
  return base64UrlToBytes(jwk.x);
}

function readRawX25519PrivateKey(obj: KeyObject): Uint8Array {
  const jwk = obj.export({ format: 'jwk' }) as { d?: string };
  if (!jwk.d) throw new Error('X25519 private key has no JWK d field');
  return base64UrlToBytes(jwk.d);
}

function buildPublicKeyObject(raw32: Uint8Array): KeyObject {
  // Wrap the raw 32-byte public key as a SPKI DER for use with diffieHellman().
  // X25519 SPKI prefix is the 12-byte OID encoding followed by the raw 32-byte key.
  const header = Buffer.from([
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00,
  ]);
  const spki = Buffer.concat([header, Buffer.from(raw32)]);
  // Compute via JWK w/ x base64url to get a KeyObject — equivalent to SPKI.
  const x = bytesToBase64Url(raw32);
  const { createPublicKey } = require('node:crypto') as typeof import('node:crypto');
  return createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x }, format: 'jwk' });
}

function base64UrlToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=');
  const buf = Buffer.from(padded, 'base64');
  return new Uint8Array(buf);
}

function bytesToBase64Url(b: Uint8Array): string {
  return Buffer.from(b).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function u32Length(len: number): Buffer {
  const buf = Buffer.alloc(4);
  buf.writeUInt32BE(len, 0);
  return buf;
}

function pushLengthPrefixed(chunks: Buffer[], value: Uint8Array): void {
  chunks.push(u32Length(value.length));
  chunks.push(Buffer.from(value));
}

function deriveBytes(
  sharedSecret: Uint8Array,
  salt: Uint8Array,
  label: string,
  length: number,
): Uint8Array {
  const out = hkdfSync(
    'sha256',
    Buffer.from(sharedSecret),
    Buffer.from(salt),
    Buffer.from(label, 'utf-8'),
    length,
  );
  return new Uint8Array(out);
}
