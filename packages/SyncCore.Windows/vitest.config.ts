import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['tests/**/*.spec.ts'],
    globals: false,
    testTimeout: 10_000,
    pool: 'forks',
    fileParallelism: false,
    // Windows: enable consistent cleanup so SQLite WAL/journal locks
    // close before the temp dir is removed.
    isolate: true,
  },
});
