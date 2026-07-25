// DestinationStore — persists the user-selected destination folder path
// and verifies it is still present at startup. Mirrors
// `apps/macos/Sources/DestinationBookmarkStore.swift`.

import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname } from 'node:path';

interface StoredDestination {
  path: string;
  mtimeMs: number;
}

export class DestinationStore {
  constructor(private readonly filePath: string) {}

  save(path: string): void {
    const mtimeMs = statSync(path).mtimeMs;
    mkdirSync(dirname(this.filePath), { recursive: true });
    writeFileSync(this.filePath, JSON.stringify({ path, mtimeMs }), 'utf-8');
  }

  resolve(): string | null {
    if (!existsSync(this.filePath)) return null;
    try {
      const obj = JSON.parse(readFileSync(this.filePath, 'utf-8')) as StoredDestination;
      if (!existsSync(obj.path)) return null;
      const stat = statSync(obj.path);
      if (!stat.isDirectory()) return null;
      // Reject if the directory has been replaced since the user picked it.
      if (Math.abs(stat.mtimeMs - obj.mtimeMs) > 1) return null;
      return obj.path;
    } catch {
      return null;
    }
  }

  clear(): void {
    if (existsSync(this.filePath)) {
      writeFileSync(this.filePath, JSON.stringify({ path: null }), 'utf-8');
    }
  }

  exists(path: string): boolean {
    if (!existsSync(path)) return false;
    return statSync(path).isDirectory();
  }
}
