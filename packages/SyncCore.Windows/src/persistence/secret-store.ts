// SecretStore — wraps Electron `safeStorage` (DPAPI on Windows) to persist the
// paired peer JSON (PSK + identity + opaque peer ID). Mirrors
// `packages/SyncCore/Sources/SyncCore/KeychainSecretStore.swift` and
// `apps/macos/Sources/...` Keychain usage at the macOS receiver.

import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { dirname } from 'node:path';

export interface SecretStoreOptions {
  safeStorage: {
    isEncryptionAvailable(): boolean;
    encryptString(plain: string): Buffer;
    decryptString(encrypted: Buffer): string;
  };
  filePath: string;
}

export class SecretStore {
  constructor(private readonly options: SecretStoreOptions) {}

  save(account: string, value: unknown): void {
    if (!this.options.safeStorage.isEncryptionAvailable()) {
      throw new Error('SecretStore: safeStorage encryption is not available');
    }
    const plain = JSON.stringify(value);
    const encrypted = this.options.safeStorage.encryptString(plain);
    mkdirSync(dirname(this.options.filePath), { recursive: true });
    const payload = JSON.stringify({ account, blob: encrypted.toString('base64') });
    writeFileSync(this.options.filePath, payload, 'utf-8');
  }

  load<T>(account: string): T | null {
    if (!existsSync(this.options.filePath)) return null;
    try {
      const obj = JSON.parse(readFileSync(this.options.filePath, 'utf-8')) as {
        account: string;
        blob: string;
      };
      if (obj.account !== account) return null;
      const decrypted = this.options.safeStorage.decryptString(Buffer.from(obj.blob, 'base64'));
      return JSON.parse(decrypted) as T;
    } catch {
      return null;
    }
  }

  delete(account: string): void {
    if (!existsSync(this.options.filePath)) return;
    try {
      const obj = JSON.parse(readFileSync(this.options.filePath, 'utf-8')) as { account: string };
      if (obj.account === account) {
        unlinkSync(this.options.filePath);
      }
    } catch {
      // ignore
    }
  }
}
