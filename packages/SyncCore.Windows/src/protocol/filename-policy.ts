// FilenamePolicy — Sanitises an original filename into a safe relative path
// and asserts structural invariants on the resourceID / role. Mirrors
// `packages/SyncCore/Sources/SyncCore/FilenamePolicy.swift` and adds NTFS
// rules (reserved names + trailing dot/space + case-insensitive match).
//
// Path layout produced by `relativePath`:
//   <YYYY>/<MM>/<stem>__<prefix>[_<role>].<ext>
//
// `prefix` is the first `prefixLength` (default 8) hex characters of the
// resourceID. If `<resourceID prefix length> < 8` we fall back to the full
// 64-char resourceID.

export const RESOURCE_ID_LENGTH = 64;
const RESOURCE_ID_REGEX = /^[0-9a-fA-F]{64}$/;
const ROLE_REGEX = /^[A-Za-z0-9_-]+$/;
const NTFS_RESERVED = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;

export class FilenamePolicyError extends Error {
  constructor(message: string, public readonly code: 'invalidFilename' | 'invalidResourceID' | 'invalidRole') {
    super(message);
    this.name = 'FilenamePolicyError';
  }
}

export interface FilenamePolicyInput {
  filename: string;
  resourceID: string;
  creationDate?: Date;
  role?: string;
  prefixLength?: number;
}

export class FilenamePolicy {
  static assertResourceID(resourceID: string): void {
    if (!RESOURCE_ID_REGEX.test(resourceID)) {
      throw new FilenamePolicyError(`invalid resourceID: ${resourceID}`, 'invalidResourceID');
    }
  }

  static assertRole(role: string | undefined): void {
    if (role === undefined) return;
    if (role === '' || !ROLE_REGEX.test(role)) {
      throw new FilenamePolicyError(`invalid role: ${role}`, 'invalidRole');
    }
  }

  static assertFilename(filename: string): void {
    if (filename.length === 0) {
      throw new FilenamePolicyError('empty filename', 'invalidFilename');
    }
    if (filename === '.' || filename === '..') {
      throw new FilenamePolicyError(`forbidden filename: ${filename}`, 'invalidFilename');
    }
    if (filename.startsWith('.')) {
      throw new FilenamePolicyError(`hidden filename: ${filename}`, 'invalidFilename');
    }
    if (filename.includes('/') || filename.includes('\\')) {
      throw new FilenamePolicyError(`path separator in filename: ${filename}`, 'invalidFilename');
    }
    for (const ch of filename) {
      const code = ch.codePointAt(0) ?? 0;
      if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) {
        throw new FilenamePolicyError(`control char in filename: ${filename}`, 'invalidFilename');
      }
    }
    // NTFS: trailing dot or space rejected.
    if (filename.endsWith('.') || filename.endsWith(' ')) {
      throw new FilenamePolicyError(`NTFS trailing dot/space: ${filename}`, 'invalidFilename');
    }
    // NTFS reserved names (without extension).
    const baseSegment = filename.split('.').shift() ?? '';
    if (NTFS_RESERVED.test(baseSegment)) {
      throw new FilenamePolicyError(`NTFS reserved name: ${filename}`, 'invalidFilename');
    }
  }

  static relativePath(input: FilenamePolicyInput): string {
    const prefixLength = input.prefixLength ?? 8;
    FilenamePolicy.assertFilename(input.filename);
    FilenamePolicy.assertResourceID(input.resourceID);
    FilenamePolicy.assertRole(input.role);
    if (prefixLength < 8 || prefixLength > input.resourceID.length) {
      throw new FilenamePolicyError(
        `prefixLength ${prefixLength} out of [8, ${input.resourceID.length}]`,
        'invalidResourceID',
      );
    }

    const dotIndex = input.filename.lastIndexOf('.');
    let stem: string;
    let ext: string;
    if (dotIndex <= 0) {
      stem = input.filename;
      ext = '';
    } else {
      stem = input.filename.slice(0, dotIndex);
      ext = input.filename.slice(dotIndex + 1);
    }
    if (stem.length === 0 || stem === '.' || stem === '..' || stem.startsWith('.')) {
      throw new FilenamePolicyError(`invalid stem: ${stem}`, 'invalidFilename');
    }

    const d = input.creationDate ?? new Date(0);
    const year = String(d.getUTCFullYear()).padStart(4, '0');
    const month = String(d.getUTCMonth() + 1).padStart(2, '0');
    const prefix = input.resourceID.slice(0, prefixLength);
    const rolePart = input.role && input.role.length > 0 ? `_${input.role}` : '';
    const extPart = ext.length > 0 ? `.${ext}` : '';
    return `${year}/${month}/${stem}__${prefix}${rolePart}${extPart}`;
  }
}
