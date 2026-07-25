// AlbumFolderPolicy — sanitises an album name into a safe folder name and
// handles `(2)…(10000)` collision suffixes via `nextAvailableFolder`.
//
// Mirrors `AlbumFolderPolicy.swift` and adds NTFS-specific rules:
//   - reserved names (CON / PRN / AUX / NUL / COM1-9 / LPT1-9)
//   - trailing dot / space rejection
//   - case-insensitive collision detection

const NTFS_RESERVED = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;

export class AlbumFolderPolicy {
  static readonly fallbackName = 'Untitled Album';

  /** Sanitise an album name into a single path-safe component. */
  static folderName(albumName: string): string {
    const trimmed = (albumName ?? '').trim();
    if (trimmed.length === 0) return AlbumFolderPolicy.fallbackName;

    let out = '';
    for (const ch of trimmed) {
      const code = ch.codePointAt(0) ?? 0;
      // control characters (U+0000..U+001F, U+007F..U+009F) → `_`
      if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) {
        out += '_';
      } else if (ch === '/' || ch === '\\') {
        out += '_';
      } else {
        out += ch;
      }
    }

    // NTFS reserved names: prepend `_` if the result equals a reserved name.
    if (NTFS_RESERVED.test(out)) {
      out = `_${out}`;
    }
    // `.` / `..` / hidden (leading dot) → prepend `_`.
    if (out === '.' || out === '..' || out.startsWith('.')) {
      out = `_${out}`;
    }
    // Trailing dot or space → trim and append `_` so the path remains valid.
    if (out.endsWith('.') || out.endsWith(' ')) {
      out = out.replace(/[. ]+$/, '') + '_';
    }
    return out;
  }

  /**
   * Given a sanitised base name and a list of folder names already in use,
   * return the first name that doesn't collide. Mirrors `nextDestinationFolderName`
   * in `ManifestStore.swift`: try `(2)` … `(10000)`; fallback to `(UUID)`.
   */
  static nextAvailableFolder(baseSafeName: string, existing: ReadonlyArray<string>): string {
    const taken = new Set(
      existing.map((n) => n.toLocaleLowerCase()),
    );
    if (!taken.has(baseSafeName.toLocaleLowerCase())) return baseSafeName;
    for (let i = 2; i <= 10_000; i++) {
      const candidate = `${baseSafeName} (${i})`;
      if (!taken.has(candidate.toLocaleLowerCase())) return candidate;
    }
    const uuid = crypto.randomUUID();
    return `${baseSafeName} (${uuid})`;
  }
}
