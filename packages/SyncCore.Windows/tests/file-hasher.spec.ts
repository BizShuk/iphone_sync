import { describe, expect, it } from 'vitest';
import { FileHasher } from '../src/crypto';

describe('FileHasher', () => {
  it('fileHasherMatchesKnownSHA256', () => {
    const input = Buffer.from('abc', 'utf-8');
    expect(FileHasher.sha256Hex(input)).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  it('matchesForEmpty', () => {
    expect(FileHasher.sha256Hex(Buffer.alloc(0))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });
});
