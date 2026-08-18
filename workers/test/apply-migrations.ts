import { applyD1Migrations, env } from 'cloudflare:test';

// Every test file gets a freshly migrated database. `isolatedStorage` then rolls back
// whatever each test wrote, so no test can be made to pass by another test's leftovers.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
