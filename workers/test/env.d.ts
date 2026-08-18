import type { D1Migration } from '@cloudflare/vitest-pool-workers';

declare global {
  namespace Cloudflare {
    interface Env {
      /** Injected by vitest.config.ts so setup can migrate the test database. */
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
