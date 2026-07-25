import { describe, expect, it } from 'vitest';
import { FilenamePolicy, FilenamePolicyError, ResourceIdentity } from '../src/protocol';

describe('ResourceIdentity', () => {
  it('resourceIdentityIsStableAndBindingScoped', () => {
    const desc = {
      assetLocalIdentifier: 'L0/001',
      resourceType: 'PHAssetResourceTypePhoto',
      originalFilename: 'IMG_0001.HEIC',
      duplicateOrdinal: 0,
    };
    const a = ResourceIdentity.make('binding-a', desc);
    const b = ResourceIdentity.make('binding-a', desc);
    expect(a).toBe(b);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    const c = ResourceIdentity.make('binding-b', desc);
    expect(a).not.toBe(c);
  });
});

describe('FilenamePolicy', () => {
  it('filenamePolicyRejectsTraversal', () => {
    expect(() =>
      FilenamePolicy.relativePath({
        filename: '../secret',
        resourceID: 'a'.repeat(64),
      }),
    ).toThrowError(FilenamePolicyError);
  });

  it('filenamePolicyGroupsByUTCMonthAndKeepsRole', () => {
    const resourceID = 'abcdef01'.padEnd(64, '0');
    const path = FilenamePolicy.relativePath({
      filename: 'IMG 0001.MOV',
      resourceID,
      creationDate: new Date('2026-07-23T00:00:00Z'),
      role: 'paired-video',
    });
    expect(path).toBe('2026/07/IMG 0001__abcdef01_paired-video.MOV');
  });

  it('rejectsNTFSReservedName', () => {
    expect(() =>
      FilenamePolicy.relativePath({
        filename: 'CON.txt',
        resourceID: 'a'.repeat(64),
      }),
    ).toThrowError(/reserved/);
  });

  it('rejectsTrailingDot', () => {
    expect(() =>
      FilenamePolicy.relativePath({
        filename: 'IMG 0001.JPG.',
        resourceID: 'a'.repeat(64),
      }),
    ).toThrowError(/NTFS trailing/);
  });

  it('requiresHexResourceID', () => {
    expect(() =>
      FilenamePolicy.relativePath({
        filename: 'IMG_0001.JPG',
        resourceID: 'not-hex',
      }),
    ).toThrowError(/invalid resourceID/);
  });
});
