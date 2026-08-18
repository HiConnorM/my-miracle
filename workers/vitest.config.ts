import { defineConfig } from 'vitest/config';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';

/**
 * Tests run inside the real workerd runtime against a real D1 database, not a mock.
 *
 * That matters more here than it usually would: D1 has no row-level security, so these
 * tests are the only thing standing between a bug and someone's private prayer. A mocked
 * database would prove the code calls itself correctly and nothing about whether the
 * authorization actually holds.
 */
export default defineConfig(async () => {
  const migrations = await readD1Migrations('./migrations');

  return {
    plugins: [
      // Note: `isolatedStorage` was removed from the pool's options in 0.21, and unknown
      // keys are silently stripped — passing it would look like isolation while giving
      // none. Tests call `resetDatabase()` in `beforeEach` instead, which is explicit and
      // does not depend on pool internals.
      cloudflareTest({
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Test-only signing key. The real one is a Worker secret.
            SESSION_SIGNING_KEY: 'test-signing-key-not-used-anywhere-real',
          },
        },
      }),
    ],
    test: {
      setupFiles: ['./test/apply-migrations.ts'],
    },
  };
});
