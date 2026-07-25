// ResourceDescriptor / ResourceIdentity — mirror
// `packages/SyncCore/Sources/SyncCore/{ResourceDescriptor,ResourceIdentity}.swift`.
//
// resourceID = SHA256( canonical )
// canonical   = sourceBindingID \x00 assetLocalIdentifier \x00
//               resourceType \x00 originalFilename \x00 duplicateOrdinal
//   (decimal string; integer 0 also valid)

import { createHash } from 'node:crypto';

export interface ResourceDescriptor {
  assetLocalIdentifier: string;
  resourceType: string;
  originalFilename: string;
  duplicateOrdinal: number;
  contentHash: string; // lowercase hex SHA-256
  expectedSize: number;
  creationDate?: Date;
  role?: string;
}

const NUL = 0x00;

export class ResourceIdentity {
  static make(sourceBindingID: string, descriptor: {
    assetLocalIdentifier: string;
    resourceType: string;
    originalFilename: string;
    duplicateOrdinal: number;
  }): string {
    const buf = canonicalBuffer(sourceBindingID, descriptor);
    return createHash('sha256').update(buf).digest('hex');
  }
}

function canonicalBuffer(
  sourceBindingID: string,
  d: {
    assetLocalIdentifier: string;
    resourceType: string;
    originalFilename: string;
    duplicateOrdinal: number;
  },
): Buffer {
  const parts: Buffer[] = [];
  parts.push(Buffer.from(sourceBindingID, 'utf-8'));
  parts.push(Buffer.from([NUL]));
  parts.push(Buffer.from(d.assetLocalIdentifier, 'utf-8'));
  parts.push(Buffer.from([NUL]));
  parts.push(Buffer.from(d.resourceType, 'utf-8'));
  parts.push(Buffer.from([NUL]));
  parts.push(Buffer.from(d.originalFilename, 'utf-8'));
  parts.push(Buffer.from([NUL]));
  parts.push(Buffer.from(String(d.duplicateOrdinal), 'utf-8'));
  return Buffer.concat(parts);
}
