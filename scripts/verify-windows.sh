#!/usr/bin/env bash
# verify-windows.sh — cross-platform check for the Windows 11 receiver ports.
#
# Runs on macOS / Linux / Windows. The NSIS + portable packaging steps are
# Windows-only (`uname -s` MINGW/CYGWIN/MSYS); every other step (TypeScript
# build, vitest, source-invariant grep) runs on any host with node + npm.
#
# This script is invoked from `scripts/verify.sh` when both:
#   1. `node` and `npm` are on PATH
#   2. `packages/SyncCore.Windows/` and `apps/windows/` exist (this commit)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNCCORE_DIR="$ROOT_DIR/packages/SyncCore.Windows"
WINDOWS_APP_DIR="$ROOT_DIR/apps/windows"

if ! command -v node >/dev/null 2>&1; then
  echo "verify-windows.sh: node not found; skipping Windows port verification." >&2
  exit 0
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "verify-windows.sh: npm not found; skipping Windows port verification." >&2
  exit 0
fi

cd "$SYNCCORE_DIR"
echo "==> npm ci (SyncCore.Windows)"
npm ci --no-audit --no-fund --silent
echo "==> npm test (SyncCore.Windows)"
npm test --silent

cd "$ROOT_DIR"
echo "==> npm run build (SyncCore.Windows)"
(cd "$SYNCCORE_DIR" && npm run build --silent)

cd "$WINDOWS_APP_DIR"
echo "==> npm ci (apps/windows)"
npm ci --no-audit --no-fund --silent
echo "==> npm run build (apps/windows)"
npm run build --silent

# Source-string invariants. These mirror the equivalent checks in
# scripts/verify.sh for the Swift side; if any of these strings disappear
# from the Windows port, the wire-protocol contract is broken.
echo "==> checking source-string invariants"
cd "$ROOT_DIR"
require() {
  local label="$1" file="$2"
  if ! grep -F -- "$label" "$file" >/dev/null 2>&1; then
    echo "verify-windows.sh: missing '$label' in $file" >&2
    exit 1
  fi
}

require 'protocolVersion: 1' "$SYNCCORE_DIR/src/protocol/constants.ts"
# Negative-control check: this typo should NOT be present. We confirm it
# is absent so future drift (e.g. accidentally introducing `_iphones._tcp`)
# surfaces immediately.
if grep -F -- '_iphones._tcp' "$SYNCCORE_DIR/src/protocol/constants.ts" >/dev/null 2>&1; then
  echo "verify-windows.sh: unexpected typo '_iphones._tcp' in constants.ts" >&2
  exit 1
fi
require '_iphonesync._tcp' "$SYNCCORE_DIR/src/protocol/constants.ts"
require '_iphonesync-pair._tcp' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'TLS_PSK_WITH_AES_128_GCM_SHA256' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'PSK-AES128-GCM-SHA256' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iphonesync-sas-v1' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iphonesync-psk-v1' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iphonesync-identity-v1' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iphonesync-client-proof-v1' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iphonesync-server-proof-v1' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'iPhoneSync' "$SYNCCORE_DIR/src/protocol/constants.ts"
require 'SyncConstants.receivingFolderName' "$SYNCCORE_DIR/src/receiver/destination-writer.ts"
require 'partialExtension' "$SYNCCORE_DIR/src/protocol/constants.ts"
require '.partial' "$SYNCCORE_DIR/src/receiver/destination-writer.ts"
require 'window-all-closed' "$WINDOWS_APP_DIR/src/main/main.ts"
require 'launchAtLoginRequested' "$WINDOWS_APP_DIR/src/main/model-root.ts"
require 'setLoginItemSettings' "$WINDOWS_APP_DIR/src/main/auto-launch.ts"
require 'powerMonitor' "$WINDOWS_APP_DIR/src/main/recovery.ts"

# Windows-only packaging step (electron-builder must run on Windows for
# NSIS + portable artefacts to be signed and bundled correctly).
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* || "$(uname -s)" == MSYS* ]]; then
  echo "==> npm run dist (electron-builder)"
  (cd "$WINDOWS_APP_DIR" && npm run dist --silent)
fi

echo "verify-windows.sh: OK"
