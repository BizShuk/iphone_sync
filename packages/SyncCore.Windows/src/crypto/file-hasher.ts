// FileHasher — streaming SHA-256 with chunked reads at the same granularity
// as `packages/SyncCore/Sources/SyncCore/FileHasher.swift` (1 MiB chunks).
//
// Returns lowercase hex. Tests verify known vector (`"abc"` → `ba7816bf…f20015ad`).

import { createHash, type Hash } from 'node:crypto';
import { createReadStream } from 'node:fs';

const CHUNK = 1_048_576;

export class FileHasher {
  static sha256Bytes(data: Uint8Array): Uint8Array {
    const hash = createHash('sha256');
    hash.update(data);
    return new Uint8Array(hash.digest());
  }

  static sha256Hex(data: Uint8Array): string {
    return Buffer.from(FileHasher.sha256Bytes(data)).toString('hex');
  }

  static async sha256File(url: string): Promise<string> {
    const hash: Hash = createHash('sha256');
    return await new Promise<string>((resolve, reject) => {
      const stream = createReadStream(url, { highWaterMark: CHUNK });
      stream.on('data', (chunk) => hash.update(chunk));
      stream.on('end', () => resolve(hash.digest('hex')));
      stream.on('error', reject);
    });
  }

  static sha256BufferHex(buffer: Buffer): string {
    const hash = createHash('sha256');
    hash.update(buffer);
    return hash.digest('hex');
  }
}
