// PairingServer — 120-second pairing window with single-connection protection
// and 5-attempt SAS verification. Mirrors `PairingServer.swift` (Swift side)
// and `PairingServer.swift` in `apps/macos/Sources/ReceiverController.swift`.
//
// Wire flow (length-prefixed JSON):
//   1. server open → listen + advertise `_iphonesync-pair._tcp` with pairing=1
//   2. server ⇄ client: Hello { deviceID, displayName, publicKey, nonce }
//   3. server derives SAS, calls onCode(code, expiresAt)
//   4. client sends Confirm { proof } with computed proof
//   5. server verifies proof; if correct → onPaired(...) + Accepted { proof, pskIdentity }
//   6. server closes listener at expiry or after success

import { EventEmitter } from 'node:events';
import { createServer, type Server, type Socket } from 'node:net';
import { SyncConstants } from '../protocol/constants.js';
import {
  PairingCrypto,
  type PairingDerivedSecrets,
  type PairingMaterial,
} from '../crypto/pairing-crypto.js';
import {
  decodePairingMessage,
  encodePairingMessage,
  type PairingHello,
} from './pairing-protocol.js';

export interface PairingServerOptions {
  receiverID: string;
  displayName: string;
  windowSeconds?: number;
  maxAttempts?: number;
  onCode?: (code: string, expiresAt: Date) => void;
  onPaired?: (info: {
    psk: Uint8Array;
    pskIdentity: Uint8Array;
    peerDeviceID: string;
    peerDisplayName: string;
  }) => void;
  onClosed?: () => void;
  onEvent?: (event: { level: 'info' | 'success' | 'warning' | 'error'; category: string; message: string }) => void;
}

export class PairingServer extends EventEmitter {
  private readonly server: Server;
  private activeSocket: Socket | null = null;
  private timer: NodeJS.Timeout | null = null;
  private readonly opens: Promise<void>;
  private readonly windowSeconds: number;
  private readonly maxAttempts: number;
  private localPort: number | null = null;

  constructor(private readonly options: PairingServerOptions) {
    super();
    this.windowSeconds = options.windowSeconds ?? SyncConstants.pairingWindowSeconds;
    this.maxAttempts = options.maxAttempts ?? SyncConstants.pairingMaxAttempts;
    this.server = createServer((sock) => this.accept(sock));
    this.opens = new Promise<void>((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(0, '0.0.0.0', () => {
        this.server.off('error', reject);
        const address = this.server.address();
        if (address && typeof address === 'object') {
          this.localPort = address.port;
        }
        resolve();
      });
    });
  }

  async open(): Promise<void> {
    await this.opens;
    this.timer = setTimeout(() => this.close('window expired'), this.windowSeconds * 1000);
    this.emitEvent('info', 'Pairing', `Opening a ${this.windowSeconds}-second pairing window.`);
  }

  async close(reason: string = 'cancelled'): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (this.activeSocket) {
      this.activeSocket.destroy();
      this.activeSocket = null;
    }
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    this.localPort = null;
    this.emitEvent('info', 'Pairing', `Pairing window closed: ${reason}.`);
    this.options.onClosed?.();
  }

  get port(): number | null {
    return this.localPort;
  }

  private accept(sock: Socket): void {
    if (this.activeSocket) {
      // Single-connection protection — reject additional connections.
      this.emitEvent('warning', 'Pairing', 'Rejected an additional pairing connection.');
      sock.destroy();
      return;
    }
    this.activeSocket = sock;
    void this.run(sock).catch((err) => {
      this.emitEvent('error', 'Pairing', `Pairing failed: ${(err as Error).message}`);
    });
  }

  private async run(sock: Socket): Promise<void> {
    const material: PairingMaterial = PairingCrypto.makeMaterial();
    const ourHello: PairingHello = {
      deviceID: this.options.receiverID,
      displayName: this.options.displayName,
      publicKey: material.publicKey,
      nonce: material.nonce,
    };
    sock.write(Buffer.from(encodePairingMessage({ kind: 'hello', payload: ourHello })));

    // Read peer Hello.
    const decoded = await readPairingMessage(sock, 'hello');
    if (decoded.kind !== 'hello') {
      throw new Error(`expected hello, got ${decoded.kind}`);
    }
    const peerHello = decoded.payload;
    const transcript = PairingCrypto.transcriptHash({
      protocolVersion: SyncConstants.protocolVersion,
      receiverID: this.options.receiverID,
      initiatorPublicKey: peerHello.publicKey,
      receiverPublicKey: material.publicKey,
      initiatorNonce: peerHello.nonce,
      receiverNonce: material.nonce,
    });
    const sharedSecret = PairingCrypto.sharedSecretWith(
      material.privateKeyObject,
      peerHello.publicKey,
    );
    const derived: PairingDerivedSecrets = PairingCrypto.derive(sharedSecret, transcript);

    const expiresAt = new Date(Date.now() + this.windowSeconds * 1000);
    this.options.onCode?.(derived.verificationCode, expiresAt);
    this.emitEvent('success', 'Pairing', 'Pairing code ready; waiting for the iPhone.');

    let attempts = 0;
    while (attempts < this.maxAttempts) {
      const next = await readPairingMessage(sock, 'confirm');
      if (next.kind !== 'confirm') {
        this.emitEvent('warning', 'Pairing', `Unexpected message ${next.kind}; ignoring.`);
        continue;
      }
      attempts += 1;
      if (PairingCrypto.constantTimeEquals(next.proof, derived.clientProof)) {
        sock.write(Buffer.from(encodePairingMessage({
          kind: 'accepted',
          proof: derived.serverProof,
          pskIdentity: derived.pskIdentity,
        })));
        this.options.onPaired?.({
          psk: derived.psk,
          pskIdentity: derived.pskIdentity,
          peerDeviceID: peerHello.deviceID,
          peerDisplayName: peerHello.displayName,
        });
        this.emitEvent('success', 'Pairing', `Paired with " ${peerHello.displayName} ".`);
        await this.close('paired');
        return;
      }
      const remaining = this.maxAttempts - attempts;
      this.emitEvent('warning', 'Pairing', `Code mismatch (${remaining} attempts remaining).`);
      sock.write(Buffer.from(encodePairingMessage({
        kind: 'rejected',
        reason: 'invalid-proof',
      })));
    }
    this.emitEvent('error', 'Pairing', 'All pairing attempts exhausted.');
    await this.close('attempts exhausted');
  }

  private emitEvent(
    level: 'info' | 'success' | 'warning' | 'error',
    category: string,
    message: string,
  ): void {
    this.options.onEvent?.({ level, category, message });
  }
}

async function readPairingMessage(
  sock: Socket,
  expectedKind: 'hello' | 'confirm',
): Promise<ReturnType<typeof decodePairingMessage>> {
  // Read 4 bytes length, then `length` bytes JSON.
  const lenBuf = await readExactly(sock, 4);
  const length = lenBuf.readUInt32BE(0);
  if (length > SyncConstants.maximumControlPayload) {
    throw new Error('pairing payload too large');
  }
  const body = await readExactly(sock, length);
  const decoded = decodePairingMessage(Buffer.concat([lenBuf, body]));
  if (expectedKind === 'hello' && decoded.kind !== 'hello') {
    throw new Error(`expected hello, got ${decoded.kind}`);
  }
  if (expectedKind === 'confirm' && decoded.kind !== 'confirm') {
    throw new Error(`expected confirm, got ${decoded.kind}`);
  }
  return decoded;
}

function readExactly(sock: Socket, length: number): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let received = 0;
    const onData = (chunk: Buffer): void => {
      const remaining = length - received;
      if (chunk.length >= remaining) {
        chunks.push(chunk.subarray(0, remaining));
        received += remaining;
        sock.off('data', onData);
        sock.off('error', onError);
        sock.off('close', onClose);
        resolve(Buffer.concat(chunks));
        return;
      }
      chunks.push(chunk);
      received += chunk.length;
    };
    const onError = (err: Error): void => {
      sock.off('data', onData);
      sock.off('close', onClose);
      reject(err);
    };
    const onClose = () => {
      sock.off('data', onData);
      sock.off('error', onError);
      reject(new Error('socket closed mid-read'));
    };
    sock.on('data', onData);
    sock.once('error', onError);
    sock.once('close', onClose);
  });
}
