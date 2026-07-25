// ManifestStore — SQLite-backed port of `ManifestStore.swift`.
//
// Three tables mirror the SwiftData `@Model` entities:
//   source_records, album_records, transfer_records.
// PKs / uniqueness / index mirror `ManifestStore.swift`.

import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHash } from 'node:crypto';
import BetterSqlite3, { type Database } from 'better-sqlite3';

export interface SourceRecord {
  sourceBindingID: string;
  albumID?: string;
  albumName?: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface AlbumRecord {
  albumBindingKey: string;
  sourceBindingID: string;
  albumID: string;
  albumName: string;
  destinationFolderName: string;
  createdAt: Date;
  updatedAt: Date;
}

export type TransferStatus = 'pending' | 'transferring' | 'committed' | 'failed';

export interface TransferRecord {
  resourceID: string;
  sourceBindingID: string;
  albumID: string;
  logicalResourceID: string;
  contentHash: string;
  expectedSize: number;
  confirmedOffset: number;
  status: TransferStatus;
  finalRelativePath: string | null;
  updatedAt: Date;
}

export interface ResourceOfferLike {
  resourceID: string;
  descriptor: {
    contentHash: string;
    expectedSize: number;
  };
}

export type ManifestDecision =
  | { kind: 'skip' }
  | { kind: 'start'; offset: number }
  | { kind: 'resume'; offset: number };

export class ManifestStore {
  private readonly db: Database;
  private readonly sourceBindingID: string;

  private constructor(db: Database, sourceBindingID: string) {
    this.db = db;
    this.sourceBindingID = sourceBindingID;
  }

  static open(filePath: string, sourceBindingID: string): ManifestStore {
    mkdirSync(dirname(filePath), { recursive: true });
    const db = new BetterSqlite3(filePath);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    ManifestStore.createSchema(db);
    return new ManifestStore(db, sourceBindingID);
  }

  private static createSchema(db: Database): void {
    db.exec(`
      CREATE TABLE IF NOT EXISTS source_records (
        source_binding_id TEXT PRIMARY KEY,
        album_id TEXT,
        album_name TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS album_records (
        album_binding_key TEXT PRIMARY KEY,
        source_binding_id TEXT NOT NULL,
        album_id TEXT NOT NULL,
        album_name TEXT NOT NULL,
        destination_folder_name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_album_records_source
        ON album_records(source_binding_id);

      CREATE TABLE IF NOT EXISTS transfer_records (
        resource_id TEXT PRIMARY KEY,
        source_binding_id TEXT NOT NULL,
        album_id TEXT NOT NULL,
        logical_resource_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        expected_size INTEGER NOT NULL,
        confirmed_offset INTEGER NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending','transferring','committed','failed')),
        final_relative_path TEXT,
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_transfer_records_album
        ON transfer_records(source_binding_id, album_id);
    `);
  }

  acceptSession(albumID: string, albumName: string, requestedBindingID?: string): {
    sourceBindingID: string;
    album: {
      albumID: string;
      albumName: string;
      destinationFolderName: string;
    };
  } {
    if (requestedBindingID && requestedBindingID !== this.sourceBindingID) {
      throw new Error('sourceBindingMismatch');
    }
    const now = new Date().toISOString();
    const insertSource = this.db.prepare(`
      INSERT INTO source_records (source_binding_id, album_id, album_name, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_binding_id) DO UPDATE SET
        album_id = excluded.album_id,
        album_name = excluded.album_name,
        updated_at = excluded.updated_at
    `);
    insertSource.run(this.sourceBindingID, albumID, albumName, now, now);

    const albumKey = albumBindingKey(this.sourceBindingID, albumID);
    const existingAlbum = this.db.prepare(
      'SELECT destination_folder_name FROM album_records WHERE album_binding_key = ?',
    ).get(albumKey) as { destination_folder_name: string } | undefined;
    const existingNames = (this.db.prepare(
      'SELECT destination_folder_name FROM album_records WHERE source_binding_id = ?',
    ).all(this.sourceBindingID) as Array<{ destination_folder_name: string }>).map(
      (r) => r.destination_folder_name,
    );
    const safe = safeAlbumName(albumName);
    const folderName = existingAlbum?.destination_folder_name
      ?? resolveUniqueFolder(safe, existingNames);
    const insertAlbum = this.db.prepare(`
      INSERT INTO album_records (album_binding_key, source_binding_id, album_id, album_name, destination_folder_name, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(album_binding_key) DO UPDATE SET
        album_name = excluded.album_name,
        destination_folder_name = excluded.destination_folder_name,
        updated_at = excluded.updated_at
    `);
    insertAlbum.run(albumKey, this.sourceBindingID, albumID, albumName, folderName, now, now);
    return {
      sourceBindingID: this.sourceBindingID,
      album: { albumID, albumName, destinationFolderName: folderName },
    };
  }

  decisionFor(offer: ResourceOfferLike): ManifestDecision {
    const row = this.db.prepare(
      'SELECT confirmed_offset, expected_size, content_hash, status FROM transfer_records WHERE resource_id = ?',
    ).get(offer.resourceID) as
      | { confirmed_offset: number; expected_size: number; content_hash: string; status: TransferStatus }
      | undefined;
    if (!row) return { kind: 'start', offset: 0 };
    if (row.content_hash !== offer.descriptor.contentHash
        || row.expected_size !== offer.descriptor.expectedSize) {
      // Hash or size changed → reset and start over.
      this.db.prepare(
        'UPDATE transfer_records SET confirmed_offset = 0, status = ?, final_relative_path = NULL, updated_at = ? WHERE resource_id = ?',
      ).run('transferring', new Date().toISOString(), offer.resourceID);
      return { kind: 'start', offset: 0 };
    }
    if (row.status === 'committed') return { kind: 'skip' };
    if (row.status === 'transferring') {
      return { kind: 'resume', offset: row.confirmed_offset };
    }
    return { kind: 'start', offset: 0 };
  }

  recordCheckpoint(resourceID: string, offset: number): void {
    this.db.prepare(
      'UPDATE transfer_records SET confirmed_offset = ?, status = ?, updated_at = ? WHERE resource_id = ?',
    ).run(offset, 'transferring', new Date().toISOString(), resourceID);
  }

  ensureTransferRecord(offer: ResourceOfferLike, logicalResourceID: string, albumID: string): void {
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO transfer_records
        (resource_id, source_binding_id, album_id, logical_resource_id, content_hash, expected_size, confirmed_offset, status, final_relative_path, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 0, 'pending', NULL, ?)
      ON CONFLICT(resource_id) DO NOTHING
    `).run(
      offer.resourceID,
      this.sourceBindingID,
      albumID,
      logicalResourceID,
      offer.descriptor.contentHash,
      offer.descriptor.expectedSize,
      now,
    );
  }

  commit(resourceID: string, relativePath: string): void {
    const row = this.db.prepare(
      'SELECT expected_size FROM transfer_records WHERE resource_id = ?',
    ).get(resourceID) as { expected_size: number } | undefined;
    if (!row) return;
    this.db.prepare(
      'UPDATE transfer_records SET confirmed_offset = ?, status = ?, final_relative_path = ?, updated_at = ? WHERE resource_id = ?',
    ).run(row.expected_size, 'committed', relativePath, new Date().toISOString(), resourceID);
  }

  reset(resourceID: string): void {
    this.db.prepare(
      'UPDATE transfer_records SET confirmed_offset = 0, status = ?, final_relative_path = NULL, updated_at = ? WHERE resource_id = ?',
    ).run('transferring', new Date().toISOString(), resourceID);
  }

  snapshot(resourceID: string): TransferRecord | null {
    const row = this.db.prepare(
      'SELECT * FROM transfer_records WHERE resource_id = ?',
    ).get(resourceID) as Record<string, unknown> | undefined;
    if (!row) return null;
    return {
      resourceID: row.resource_id as string,
      sourceBindingID: row.source_binding_id as string,
      albumID: row.album_id as string,
      logicalResourceID: row.logical_resource_id as string,
      contentHash: row.content_hash as string,
      expectedSize: row.expected_size as number,
      confirmedOffset: row.confirmed_offset as number,
      status: row.status as TransferStatus,
      finalRelativePath: row.final_relative_path as string | null,
      updatedAt: new Date(row.updated_at as string),
    };
  }

  close(): void {
    this.db.close();
  }
}

function albumBindingKey(sourceBindingID: string, albumID: string): string {
  const buf = Buffer.concat([
    Buffer.from('album', 'utf-8'),
    Buffer.from([0]),
    Buffer.from(sourceBindingID, 'utf-8'),
    Buffer.from([0]),
    Buffer.from(albumID, 'utf-8'),
  ]);
  return createHash('sha256').update(buf).digest('hex');
}

function safeAlbumName(name: string): string {
  return sanitizeAlbumName(name);
}

function sanitizeAlbumName(name: string): string {
  const trimmed = (name || '').trim();
  if (trimmed.length === 0) return 'Untitled Album';
  let out = '';
  for (const ch of trimmed) {
    const code = ch.codePointAt(0) ?? 0;
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) {
      out += '_';
    } else if (ch === '/' || ch === '\\') {
      out += '_';
    } else {
      out += ch;
    }
  }
  if (out === '.' || out === '..' || out.startsWith('.')) out = `_${out}`;
  if (out.endsWith('.') || out.endsWith(' ')) out = out.replace(/[. ]+$/, '') + '_';
  return out;
}

function resolveUniqueFolder(base: string, existing: ReadonlyArray<string>): string {
  const taken = new Set(existing.map((n) => n.toLocaleLowerCase()));
  if (!taken.has(base.toLocaleLowerCase())) return base;
  for (let i = 2; i <= 10_000; i++) {
    const candidate = `${base} (${i})`;
    if (!taken.has(candidate.toLocaleLowerCase())) return candidate;
  }
  return `${base} (${randomUUID()})`;
}

function randomUUID(): string {
  // Lazy require to avoid pulling uuid at module top-level.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  return require('node:crypto').randomUUID();
}
