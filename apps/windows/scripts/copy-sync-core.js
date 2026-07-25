#!/usr/bin/env node
// Replace the symlinked `node_modules/@iphonesync/synccore-windows` dist
// with a real copy. `npm install` symlinks the package directory because
// of the `file:../../packages/SyncCore.Windows` dependency, but electron-builder
// requires all packed files to be INSIDE the app root — the symlink's
// resolved target is outside and so asar packing aborts.
//
// We replace `node_modules/@iphonesync/synccore-windows` itself (a symlink)
// with a real directory containing `package.json` (copied from the source)
// plus `dist/` (copied from the source's build output). This makes the
// whole package "real" on disk from electron-builder's perspective.

import { cp, mkdir, rm, lstat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..', '..');
const srcRoot = resolve(repoRoot, 'packages', 'SyncCore.Windows');
const pkgDir = resolve(here, '..', 'node_modules', '@iphonesync', 'synccore-windows');
const srcDist = resolve(srcRoot, 'dist');

if (!existsSync(srcDist)) {
  console.warn(`copy-sync-core: source dist not found yet: ${srcDist}`);
  console.warn('Run `npm run build` in packages/SyncCore.Windows to materialise the dist.');
  console.warn('Skipping copy; electron-builder will fail if dist is missing.');
  process.exit(0);
}

// 1. Remove the symlink if present.
const pkgStat = await lstat(pkgDir).catch(() => null);
if (pkgStat) {
  await rm(pkgDir, { recursive: true, force: true });
}

// 2. Recreate the package directory as a real directory.
await mkdir(pkgDir, { recursive: true });

// 3. Copy the original package.json (electron-builder needs it to resolve
//    the entry point).
await cp(resolve(srcRoot, 'package.json'), resolve(pkgDir, 'package.json'));

// 4. Copy the dist directory.
await cp(srcDist, resolve(pkgDir, 'dist'), { recursive: true });

console.log(`copy-sync-core: replaced symlink with real copy at ${pkgDir}`);
