import { describe, expect, it, beforeEach } from 'vitest';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ManifestStore } from '../src/receiver/manifest-store';

describe('ManifestStore', () => {
  let dir: string;
  let filePath: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'manifest-'));
    filePath = join(dir, 'db.sqlite');
  });

  it('manifestStartsResumesAndSkipsCommittedResource', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    store.acceptSession('album-A', 'Trip');
    const offer = {
      resourceID: 'r-1',
      descriptor: { contentHash: 'a'.repeat(64), expectedSize: 1024 },
    };
    store.ensureTransferRecord(offer, 'logical-1', 'album-A');
    expect(store.decisionFor(offer).kind).toBe('start');
    store.recordCheckpoint('r-1', 512);
    expect(store.decisionFor(offer).kind).toBe('resume');
    store.commit('r-1', 'iPhoneSync/A/2026/07/x.jpg');
    expect(store.decisionFor(offer).kind).toBe('skip');
    store.close();
  });

  it('duplicateAlbumNamesReceiveStableDistinctFolderNames', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    const a1 = store.acceptSession('PhotoLibrary/local/A', 'Family');
    const a2 = store.acceptSession('PhotoLibrary/local/B', 'Family');
    expect(a1.album.destinationFolderName).toBe('Family');
    expect(a2.album.destinationFolderName).toBe('Family (2)');
    store.close();
  });

  it('manifestRejectsAnUnknownSourceBinding', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    expect(() => store.acceptSession('A', 'Album', 'different-binding')).toThrowError(
      /sourceBindingMismatch/,
    );
    store.close();
  });

  it('resetClearsOffsetAndPath', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    store.acceptSession('album-A', 'Trip');
    const offer = {
      resourceID: 'r-1',
      descriptor: { contentHash: 'a'.repeat(64), expectedSize: 1024 },
    };
    store.ensureTransferRecord(offer, 'logical-1', 'album-A');
    store.recordCheckpoint('r-1', 512);
    store.reset('r-1');
    const decision = store.decisionFor(offer);
    expect(decision.kind).toBe('resume');
    expect((decision as { offset: number }).offset).toBe(0);
    store.close();
  });

  it('snapshotReturnsRecordAfterCommit', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    store.acceptSession('album-A', 'Trip');
    const offer = {
      resourceID: 'r-1',
      descriptor: { contentHash: 'a'.repeat(64), expectedSize: 1024 },
    };
    store.ensureTransferRecord(offer, 'logical-1', 'album-A');
    store.commit('r-1', 'iPhoneSync/A/2026/07/x.jpg');
    const snap = store.snapshot('r-1');
    expect(snap).not.toBe(null);
    expect(snap?.status).toBe('committed');
    expect(snap?.finalRelativePath).toBe('iPhoneSync/A/2026/07/x.jpg');
    store.close();
  });

  it('decisionForResetsWhenHashChanges', () => {
    const store = ManifestStore.open(filePath, 'binding-1');
    store.acceptSession('A', 'Album');
    const offer = {
      resourceID: 'r-1',
      descriptor: { contentHash: 'a'.repeat(64), expectedSize: 1024 },
    };
    store.ensureTransferRecord(offer, 'logical-1', 'album-A');
    store.recordCheckpoint('r-1', 512);
    const changed = {
      resourceID: 'r-1',
      descriptor: { contentHash: 'b'.repeat(64), expectedSize: 1024 },
    };
    expect(store.decisionFor(changed).kind).toBe('start');
    store.close();
  });
});
