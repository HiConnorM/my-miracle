# My Miracles

*Remember the good. Carry each other.*

A native iOS app for privately recording the moments you never want to forget, with an
optional community that can pray with you while the story is still unfolding.

```text
Something is happening → Ask for prayer → People tap "I prayed" → Post an update
→ Mark it answered → Turn it into a Miracle → It enters your permanent Journal
→ People who prayed receive closure → Months later, "On This Day"
```

## Getting started

Requires Xcode 26 or later and Node 20 or later.

Set up the local database and start the Worker:

```bash
cd workers && npm install && npm run db:reset:local && npm run dev
```

Point the app at it and build:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.Debug.xcconfig
```

```bash
scripts/build.sh
```

```bash
scripts/test.sh
```

Check the schema and its constraints — fast, no network, safe to run constantly:

```bash
workers/scripts/verify-schema.sh
```

If the app shows "This build isn't configured", the message says exactly what to fix. It
also refuses to launch on plaintext HTTP outside development, or if anything
credential-shaped ends up in the app bundle.

## Where things are

| Path | Contents |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Engineering rules. Read first. |
| [docs/product-spec.md](docs/product-spec.md) | Positioning, V1 scope, safety, monetization |
| [docs/architecture.md](docs/architecture.md) | Client and server architecture, analytics allowlist |
| [docs/database.md](docs/database.md) | Schema, authorization matrix, required adversarial tests |
| [docs/design-system.md](docs/design-system.md) | Warm sacred minimalism — palette, type, components |
| `MyMiracles/` | The app. Feature-based; synchronized file groups. |
| `workers/` | Cloudflare Worker API, D1 migrations, schema verification |
| `admin/` | Next.js moderation console — see [admin/README.md](admin/README.md) |

## Stack

Native SwiftUI client with no third-party dependencies, talking to a Cloudflare Worker over
HTTPS. D1 (SQLite) for data, R2 for media, Durable Objects for the few live surfaces,
Queues for notification dispatch. Sign in with Apple is verified in the Worker, which
issues its own rotating sessions.

**D1 has no row-level security**, so the Worker is the only authorization boundary. That is
a smaller, more auditable surface than direct database access — but a missing check has no
backstop, which is why [docs/database.md](docs/database.md#the-adversarial-matrix)
treats the adversarial matrix as the security model rather than as extra tests.

## Status

**Phase 0** — repository, build configuration, app foundation, test targets.
**Phase 1** — D1 schema: 22 tables, 33 indexes, 40 schema checks.
**Phase 2** — Worker authorization layer and the adversarial matrix.
**Phase 3** — Sign in with Apple, rotating sessions, onboarding, account deletion.
**Phase 4** — the core loop: ask, be prayed for, update, answer, remember.
**Phase 5** — the design system: tokens, components, and verified contrast.
**Phase 6** — Home: a finite session, On This Day, and a real ending.
**Phase 7** — the Journal: timeline by year and month, filters, search, export.
**Phase 8** — the social graph: profiles, follows, encouragement, saving, finding people.
**Phase 9** — moderation: staff-only queue, full audit trail, and the admin console.

Verified by 251 Worker tests, 177 iOS unit tests, 4 UI tests and 40 schema checks —
including contract tests against a live Worker and WCAG contrast measured on the shipped
asset catalog in light, dark and both high-contrast appearances.

Next: Phase 10 — notification delivery. The full order is in
[docs/product-spec.md](docs/product-spec.md#build-order).

**Requires Node 20.** Wrangler 4.123+ needs Node 22; the pinned version and the
`compatibility_date` in `workers/wrangler.jsonc` are matched to Node 20. Raise all three
together.

**Before a device build:** enable the Sign in with Apple capability for the App ID in the
Apple Developer portal. Simulator builds work without it.

The name is a **working title** pending trademark clearance.
