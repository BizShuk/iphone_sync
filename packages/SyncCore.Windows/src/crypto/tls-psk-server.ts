// TlsPskServer — Node `tls.createServer` configured for static PSK with
// `TLS_PSK_WITH_AES_128_GCM_SHA256`. Mirrors `PSKTLSParameters.make(...)`
// for the server role.
//
// The PSK callback receives the client-supplied identity hint and must look
// up the matching 32-byte PSK. On unknown identity the server MUST abort the
// handshake — mirroring the strict equality check in `PairingCrypto.swift`.

import { createServer, type Server, type TlsOptions } from 'node:tls';
import { SyncConstants } from '../protocol/constants.js';

export interface TlsPskServerOptions {
  /** Lookup table: identity hint (utf-8 string) → 32-byte PSK. */
  pskLookup: (identity: string) => Uint8Array | null;
  /** Called when a client connects (post-handshake). */
  onConnection?: (socket: import('node:net').Socket) => void;
}

export class TlsPskServer {
  private readonly server: Server;

  constructor(options: TlsPskServerOptions) {
    const tlsOptions: TlsOptions = {
      ciphers: SyncConstants.tlsPskCipherSuiteAlias,
      minVersion: 'TLSv1.2',
      maxVersion: 'TLSv1.2',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      pskCallback: (_socket: any, identity: string): any => {
        const psk = options.pskLookup(identity);
        if (psk === null) {
          return null; // abort handshake
        }
        return psk as unknown as ArrayBufferView;
      },
    };
    this.server = createServer(tlsOptions);
    if (options.onConnection) {
      this.server.on('secureConnection', (socket) => options.onConnection!(socket));
    }
  }

  /** Bind + listen; resolves with the chosen port when ready. */
  listen(host: string = '0.0.0.0', port: number = 0): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const onError = (err: Error): void => {
        this.server.off('listening', onListening);
        reject(err);
      };
      const onListening = (): void => {
        this.server.off('error', onError);
        const address = this.server.address();
        if (address && typeof address === 'object') {
          resolve(address.port);
        } else {
          reject(new Error('TlsPskServer: no listening address'));
        }
      };
      this.server.once('error', onError);
      this.server.once('listening', onListening);
      this.server.listen(port, host);
    });
  }

  close(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.server.close((err) => (err ? reject(err) : resolve()));
    });
  }

  address(): { address: string; port: number } | null {
    const a = this.server.address();
    if (a && typeof a === 'object') {
      return { address: a.address, port: a.port };
    }
    return null;
  }
}
