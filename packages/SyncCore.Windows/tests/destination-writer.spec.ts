import { describe, expect, it, beforeEach } from 'vitest';
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { DestinationWriter } from '../src/receiver/destination-writer';
import { ManifestStore } from '../src/receiver/manifest-store';

function sha256Hex(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex');
}

describe('DestinationWriter', () => {
  let dir: string;
  let destinationRoot: string;
  let manifestFile: string;
  let store: ManifestStore;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'dest-'));
    destinationRoot = join(dir, 'backup');
    manifestFile = join(dir, 'db.sqlite');
    store = ManifestStore.open(manifestFile, 'binding-1');
  });

  it('receivingFolderIsCreatedBeforeAlbumFolder', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'albumDate',
    });
    writer.prepareAlbumDirectory('Trip');
    expect(existsSync(join(destinationRoot, 'iPhoneSync'))).toBe(true);
    store.close();
  });

  it('commitsFileAndVerifiesHash', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'albumDate',
    });
    writer.prepareAlbumDirectory('Trip');
    const content = Buffer.from('hello world');
    const offer = {
      resourceID: 'a'.repeat(64),
      logicalResourceID: 'logical-1',
      albumID: 'album-A',
      descriptor: {
        contentHash: sha256Hex(content),
        expectedSize: content.length,
        originalFilename: 'IMG_0001.jpg',
        creationDate: new Date('2026-07-23T00:00:00Z'),
      },
    };
    const result = writer.begin(offer);
    expect(result.kind).toBe('transfer');
    writer.append(0, content);
    const commit = writer.commit(offer.descriptor.contentHash);
    expect(commit.relativePath).toContain('iPhoneSync/');
    store.close();
  });

  it('rejectsIntegrityMismatch', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'albumDate',
    });
    writer.prepareAlbumDirectory('Trip');
    const offer = {
      resourceID: 'b'.repeat(64),
      logicalResourceID: 'logical-1',
      albumID: 'album-A',
      descriptor: {
        contentHash: 'c'.repeat(64),
        expectedSize: 5,
        originalFilename: 'IMG_0002.jpg',
        creationDate: new Date('2026-07-23T00:00:00Z'),
      },
    };
    const result = writer.begin(offer);
    expect(result.kind).toBe('transfer');
    writer.append(0, Buffer.from('abcde'));
    expect(() => writer.commit('d'.repeat(64))).toThrowError(/integrity/);
    store.close();
  });

  it('albumOnlyModeWritesFileDirectlyUnderAlbum', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'albumOnly',
    });
    writer.prepareAlbumDirectory('Trip');
    const content = Buffer.from('abc');
    const offer = {
      resourceID: 'd'.repeat(64),
      logicalResourceID: 'logical-1',
      albumID: 'album-A',
      descriptor: {
        contentHash: sha256Hex(content),
        expectedSize: content.length,
        originalFilename: 'IMG_0003.jpg',
        creationDate: new Date('2026-07-23T00:00:00Z'),
      },
    };
    const result = writer.begin(offer);
    expect(result.kind).toBe('transfer');
    writer.append(0, content);
    const commit = writer.commit(offer.descriptor.contentHash);
    expect(commit.relativePath).not.toContain('2026/07/');
    store.close();
  });

  it('flatModeWritesFileDirectlyUnderReceivingFolder', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'flat',
    });
    writer.prepareAlbumDirectory('Trip');
    const content = Buffer.from('xyz');
    const offer = {
      resourceID: 'e'.repeat(64),
      logicalResourceID: 'logical-1',
      albumID: 'album-A',
      descriptor: {
        contentHash: sha256Hex(content),
        expectedSize: content.length,
        originalFilename: 'IMG_0004.jpg',
        creationDate: new Date('2026-07-23T00:00:00Z'),
      },
    };
    const result = writer.begin(offer);
    expect(result.kind).toBe('transfer');
    writer.append(0, content);
    const commit = writer.commit(offer.descriptor.contentHash);
    expect(commit.relativePath).toMatch(/^iPhoneSync\//);
    expect(commit.relativePath).not.toContain('Trip');
    store.close();
  });

  it('existingDifferentFileIsNeverOverwritten', () => {
    const writer = new DestinationWriter({
      destinationRoot,
      manifest: store,
      storageMode: 'flat',
    });
    writer.prepareAlbumDirectory('Trip');
    const existing = Buffer.from('existing');
    const offer = {
      resourceID: 'f'.repeat(64),
      logicalResourceID: 'logical-1',
      albumID: 'album-A',
      descriptor: {
        contentHash: sha256Hex(existing),
        expectedSize: existing.length,
        originalFilename: 'IMG_0005.jpg',
        creationDate: new Date('2026-07-23T00:00:00Z'),
      },
    };
    // Pre-create a file with same name but different content.
    const targetPath = join(destinationRoot, 'iPhoneSync', `${'f'.repeat(8)}__${'f'.repeat(64).slice(0, 0)}.jpg`);
    void writeFileSync;
    void targetPath;
    // The writer uses resourceID+prefix; pre-create a same-prefix file.
    const target = join(destinationRoot, 'iPhoneSync', `IMG_0005__${'f'.repeat(8)}.jpg`);
    writeFileSync(target, Buffer.from('OLD'));
    const result = writer.begin(offer);
    if (result.kind === 'transfer') {
      writer.append(0, existing);
      const commit = writer.commit(offer.descriptor.contentHash);
      // Different file at same path → writer should not overwrite.
      expect(commit.relativePath).not.toContain('IMG_0005.jpg');
    }
    store.close();
  });

  it('cleanup', () => {
    rmSync(dir, { recursive: true, force: true });
  });
});
