import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['tests/**/*.spec.ts'],
    globals: false,
    testTimeout: 10_000,
    pool: 'forks',
  },
});
