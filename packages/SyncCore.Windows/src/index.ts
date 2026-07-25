// SyncCore.Windows — TypeScript port of `packages/SyncCore` (Swift).
//
// Wire protocol is byte-for-byte compatible with the Apple sender so an
// iPhone running the iPhone Sync iOS app can pair with either a Mac receiver
// or a Windows 11 receiver without any change on the iOS side.

export * from './protocol/index.js';
export * from './crypto/index.js';
export * from './discovery/index.js';
export * from './pairing/index.js';
export * from './receiver/index.js';
export * from './persistence/index.js';
export * from './logging/index.js';
