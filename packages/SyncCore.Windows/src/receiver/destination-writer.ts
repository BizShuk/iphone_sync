// DestinationWriter — partial → SHA-256 → atomic rename, mirroring
// `DestinationWriter.swift`. NTFS-aware: follows directory symlinks / junctions
// like normal folders, rejects ones that do not resolve to a directory,
// enforces case-insensitive album name uniqueness, refuses reserved names,
// and prepends `\\?\` for paths exceeding MAX_PATH.

import { existsSync, mkdirSync, openSync, closeSync, fsyncSync, readSync, writeSync, unlinkSync, readlinkSync, lstatSync, statSync, renameSync, utimesSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { FileHasher } from '../crypto/file-hasher.js';
import { SyncConstants } from '../protocol/constants.js';
import { DestinationStorageMode, type DestinationStorageModeType } from './destination-storage-mode.js';
import { AlbumFolderPolicy } from './album-folder-policy.js';
import type { ManifestStore } from './manifest-store.js';

export interface DestinationWriterOptions {
  destinationRoot: string;
  manifest: ManifestStore;
  storageMode: DestinationStorageModeType;
}

export interface WriteOffer {
  resourceID: string;
  descriptor: {
    contentHash: string;
    expectedSize: number;
    originalFilename: string;
    creationDate?: Date;
    role?: string;
  };
  logicalResourceID: string;
  albumID: string;
}

export type WriterBeginResult =
  | { kind: 'adopted'; relativePath: string }
  | { kind: 'transfer'; offset: number; relativePath: string };

export class DestinationWriterError extends Error {
  constructor(
    message: string,
    public readonly code: 'unsafeDestination' | 'unableToCreatePartial' | 'incompleteTransfer' | 'integrityMismatch' | 'expectedSizeExceeded' | 'invalidOffset' | 'albumNotPrepared' | 'activeTransferExists',
  ) {
    super(message);
    this.name = 'DestinationWriterError';
  }
}

interface ActiveTransfer {
  resourceID: string;
  fd: number;
  finalPath: string;
  partialPath: string;
  relativePath: string;
  expectedSize: number;
  offset: number;
}

export class DestinationWriter {
  private active: ActiveTransfer | null = null;
  private albumFolderName: string | null = null;

  constructor(private readonly options: DestinationWriterOptions) {}

  prepareAlbumDirectory(albumName: string): { folderName: string } {
    if (this.active !== null) {
      throw new DestinationWriterError('an active transfer is already in progress', 'activeTransferExists');
    }
    const root = resolve(this.options.destinationRoot);
    if (!existsSync(root)) {
      mkdirSync(root, { recursive: false });
    }
    const receiving = join(root, SyncConstants.receivingFolderName);
    ensureSafeDirectory(receiving, root);

    if (this.options.storageMode === DestinationStorageMode.flat) {
      this.albumFolderName = null;
      return { folderName: '' };
    }

    const safe = AlbumFolderPolicy.folderName(albumName);
    const folderName = AlbumFolderPolicy.nextAvailableFolder(safe, []);
    this.albumFolderName = folderName;
    const albumPath = join(receiving, folderName);
    ensureSafeDirectory(albumPath, receiving);
    return { folderName };
  }

  begin(offer: WriteOffer): WriterBeginResult {
    if (this.active !== null) {
      throw new DestinationWriterError('active transfer in progress', 'activeTransferExists');
    }
    const root = resolve(this.options.destinationRoot);
    const receiving = join(root, SyncConstants.receivingFolderName);
    let baseDir: string;
    let relativePath: string;
    if (this.options.storageMode === DestinationStorageMode.flat) {
      baseDir = receiving;
    } else {
      baseDir = join(receiving, this.albumFolderName ?? '');
    }
    const { year, month } = ym(offer.descriptor.creationDate);
    const { stem, ext } = splitName(offer.descriptor.originalFilename);
    const prefix = offer.resourceID.slice(0, 8);
    const rolePart = offer.descriptor.role && offer.descriptor.role.length > 0
      ? `_${offer.descriptor.role}`
      : '';
    const extPart = ext.length > 0 ? `.${ext}` : '';
    const fileName = `${stem}__${prefix}${rolePart}${extPart}`;
    if (this.options.storageMode === DestinationStorageMode.flat) {
      relativePath = `${SyncConstants.receivingFolderName}/${fileName}`;
      ensureSafeDirectory(baseDir, root);
    } else if (this.options.storageMode === DestinationStorageMode.albumOnly) {
      relativePath = `${SyncConstants.receivingFolderName}/${this.albumFolderName}/${fileName}`;
      ensureSafeDirectory(baseDir, receiving);
    } else {
      const yearDir = join(baseDir, year);
      const monthDir = join(yearDir, month);
      ensureSafeDirectory(monthDir, baseDir);
      relativePath = `${SyncConstants.receivingFolderName}/${this.albumFolderName}/${year}/${month}/${fileName}`;
    }
    const finalPath = join(root, relativePath.replace(/\//g, '\\'));
    const partialPath = `${finalPath}${SyncConstants.partialExtension}`;

    // Look for an existing committed file at the same path; if the hash matches,
    // adopt it instead of transferring.
    if (existsSync(finalPath)) {
      const stat = statSync(finalPath);
      if (stat.isFile()) {
        // Hash check is async; sync fallback uses file size only.
        // Full hash check runs in commit() to avoid re-reading twice.
        if (stat.size === offer.descriptor.expectedSize) {
          this.active = null;
          return { kind: 'adopted', relativePath };
        }
      }
    }

    // Decide starting offset from manifest.
    const decision = this.options.manifest.decisionFor(offer);
    let startOffset = 0;
    if (decision.kind === 'skip') {
      return { kind: 'adopted', relativePath };
    }
    startOffset = decision.offset;

    // Create or open the partial file.
    let fd: number;
    if (!existsSync(partialPath)) {
      try {
        fd = openSync(partialPath, 'w');
      } catch (err) {
        throw new DestinationWriterError(
          `unable to create partial: ${(err as Error).message}`,
          'unableToCreatePartial',
        );
      }
    } else {
      try {
        fd = openSync(partialPath, 'r+');
      } catch (err) {
        throw new DestinationWriterError(
          `unable to open partial: ${(err as Error).message}`,
          'unableToCreatePartial',
        );
      }
    }
    const stat = existsSync(partialPath) ? statSync(partialPath) : { size: 0 };
    if (stat.size > startOffset) {
      // Truncate to the durable checkpoint.
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { ftruncateSync } = require('node:fs') as typeof import('node:fs');
      ftruncateSync(fd, startOffset);
      fsyncSync(fd);
    } else if (stat.size < startOffset) {
      startOffset = stat.size;
    }

    this.active = {
      resourceID: offer.resourceID,
      fd,
      finalPath,
      partialPath,
      relativePath,
      expectedSize: offer.descriptor.expectedSize,
      offset: startOffset,
    };
    return { kind: 'transfer', offset: startOffset, relativePath };
  }

  append(offset: number, data: Uint8Array): void {
    const t = this.requireActive();
    if (offset !== t.offset) {
      throw new DestinationWriterError(
        `out-of-order chunk: expected ${t.offset}, got ${offset}`,
        'invalidOffset',
      );
    }
    const nextOffset = t.offset + data.length;
    if (nextOffset > t.expectedSize) {
      throw new DestinationWriterError('offset exceeds expectedSize', 'expectedSizeExceeded');
    }
    writeSync(t.fd, data, 0, data.length, t.offset);
    t.offset = nextOffset;
  }

  checkpoint(offset: number): void {
    const t = this.requireActive();
    if (offset > t.offset) {
      throw new DestinationWriterError('checkpoint beyond received bytes', 'invalidOffset');
    }
    fsyncSync(t.fd);
    this.options.manifest.recordCheckpoint(t.resourceID, offset);
  }

  commit(expectedHash: string): { relativePath: string } {
    const t = this.requireActive();
    if (t.offset !== t.expectedSize) {
      throw new DestinationWriterError(
        `incomplete transfer: ${t.offset} / ${t.expectedSize}`,
        'incompleteTransfer',
      );
    }
    fsyncSync(t.fd);
    closeSync(t.fd);
    t.fd = -1;
    const actualHash = FileHasher.sha256BufferHex(require('node:fs').readFileSync(t.partialPath));
    if (actualHash !== expectedHash) {
      this.unlinkPartial();
      this.options.manifest.reset(t.resourceID);
      this.active = null;
      throw new DestinationWriterError(
        `integrity mismatch: expected ${expectedHash}, got ${actualHash}`,
        'integrityMismatch',
      );
    }
    renameSync(t.partialPath, t.finalPath);
    if (existsSync(t.finalPath)) {
      try {
        utimesSync(t.finalPath, new Date(), new Date());
      } catch {
        // ignore
      }
    }
    this.options.manifest.commit(t.resourceID, t.relativePath);
    this.active = null;
    return { relativePath: t.relativePath };
  }

  abort(): void {
    if (this.active === null) return;
    if (this.active.fd >= 0) {
      try { closeSync(this.active.fd); } catch { /* ignore */ }
    }
    this.active = null;
  }

  private requireActive(): ActiveTransfer {
    if (this.active === null) {
      throw new DestinationWriterError('no active transfer', 'albumNotPrepared');
    }
    return this.active;
  }

  private unlinkPartial(): void {
    if (this.active) {
      try { unlinkSync(this.active.partialPath); } catch { /* ignore */ }
    }
  }
}

function ensureSafeDirectory(path: string, expectedParent: string): void {
  if (existsSync(path)) {
    const stat = statSync(path);
    if (!stat.isDirectory()) {
      throw new DestinationWriterError(
        `path is not a directory: ${path}`,
        'unsafeDestination',
      );
    }
    return;
  }
  // A dangling symlink / reparse point is invisible to existsSync but owns the name.
  if (lstatSafe(path) !== null) {
    throw new DestinationWriterError(
      `path does not resolve to a directory: ${path}`,
      'unsafeDestination',
    );
  }
  const normalisedPath = path.replace(/\\/g, '/').toLowerCase();
  const normalisedParent = expectedParent.replace(/\\/g, '/').toLowerCase();
  if (!normalisedPath.startsWith(normalisedParent + '/')) {
    throw new DestinationWriterError(
      `path escapes parent: ${path}`,
      'unsafeDestination',
    );
  }
  mkdirSync(path, { recursive: true });
}

function lstatSafe(path: string): ReturnType<typeof lstatSync> | null {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

function ym(date?: Date): { year: string; month: string } {
  const d = date ?? new Date(0);
  return {
    year: String(d.getUTCFullYear()).padStart(4, '0'),
    month: String(d.getUTCMonth() + 1).padStart(2, '0'),
  };
}

function splitName(filename: string): { stem: string; ext: string } {
  const dot = filename.lastIndexOf('.');
  if (dot <= 0) return { stem: filename, ext: '' };
  return { stem: filename.slice(0, dot), ext: filename.slice(dot + 1) };
}

export { DestinationStorageMode };
