#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_NAME="$(basename "${PROJECT_DIR}")"
PROJECTS_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"
SITE_ROOT="${BIZSHUK_SITE_ROOT:-${PROJECTS_ROOT}/product/bizshuk.github.io}"

if [[ ! -f "${SITE_ROOT}/package.json" ]]; then
  echo "bizshuk.github.io checkout not found: ${SITE_ROOT}" >&2
  exit 1
fi

exec npm --prefix "${SITE_ROOT}" run release:store -- "${PROJECT_NAME}"
