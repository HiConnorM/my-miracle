# MY MIRACLES ENGINEERING RULES

My Miracles is a native iOS application for privately recording the moments you never
want to forget, with an optional community that can pray with you while the story is
still unfolding.

**Read before any substantial task:** this file, then [docs/product-spec.md](docs/product-spec.md),
[docs/architecture.md](docs/architecture.md), [docs/database.md](docs/database.md),
[docs/design-system.md](docs/design-system.md).

---

## The rules

1. This is a native iOS application.
   - Swift
   - SwiftUI
   - iOS 18+
   - async/await
   - Observation/`@Observable`
   - URLSession (no third-party networking dependency)
2. Cloudflare D1 is the server source of truth, reached only through the Worker API.
3. SwiftData is a cache/outbox only.
   Never create independent business truth locally.
4. The iOS app holds NO backend credential of any kind.
   It authenticates with a user session token obtained at sign-in.
5. Every Worker route MUST authorize explicitly.
   D1 has no row-level security. The Worker is the only boundary.
6. Never weaken an authorization check to fix an application bug.
7. Private prayer/journal text must never be sent to analytics.
8. Anonymous posts are anonymous to other users,
   NOT anonymous to the platform.
9. Anonymous identity must be separated from the client-visible post model.
10. Prayer -> Answered -> Miracle must be transactional.
11. No direct money transfer functionality in V1.
12. No DMs in V1.
13. No follower/prayer leaderboards.
14. No manipulative streak-loss mechanics.
15. Accessibility is required:
    - Dynamic Type
    - VoiceOver
    - Reduce Motion
    - sufficient contrast
16. Use Apple's native interaction patterns wherever practical.
17. Keep views dumb.
    Business logic belongs in feature models/use cases/repositories.
18. Do not introduce:
    - microservices
    - Redux-style global stores
    - unnecessary design patterns
    - custom backend servers
    - third-party libraries without justification
19. Every feature requires:
    - loading state
    - empty state
    - error state
    - offline behavior
    - accessibility labels where appropriate
20. Never silently alter schema.
    All D1 changes happen through migrations in workers/migrations/.
21. Before marking a task complete:
    - build project
    - run tests
    - inspect warnings
    - verify relevant authorization tests
    - summarize what changed

---

## How to work in this repository

Before coding:

1. Summarize the relevant architecture.
2. Identify the files expected to change.
3. Identify the security/privacy implications.

Then implement **only the requested scope**.

After implementation:

1. Build.
2. Run relevant tests.
3. Inspect warnings.
4. Review for privacy/security regressions.
5. Summarize the exact changes.
6. Identify remaining issues.

Do not expand scope without justification. Do not assume functionality that is not
present — inspect the existing implementation before modifying anything.

---

## Commands

Build for simulator:

```bash
xcodebuild -project MyMiracles.xcodeproj -scheme MyMiracles -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Run unit tests:

```bash
xcodebuild -project MyMiracles.xcodeproj -scheme MyMiracles -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Convenience wrappers live in [scripts/](scripts/): `scripts/build.sh`, `scripts/test.sh`.

Verify the database schema and its constraints (fast, no network — run it in the loop):

```bash
workers/scripts/verify-schema.sh
```

Run the Worker's authorization suite. **This is the security model** — never skip it:

```bash
cd workers && npm test
```

Reset the local D1 database to seeded state:

```bash
cd workers && npm run db:reset:local
```

---

## Project layout

| Path | Contents |
|---|---|
| `MyMiracles/App/` | App entry point, root scene, composition root |
| `MyMiracles/Core/` | Cross-cutting infrastructure — no product features |
| `MyMiracles/Features/` | One directory per feature: views + `@Observable` model + repository use |
| `MyMiracles/Models/` | Domain types shared across features |
| `MyMiracles/Resources/` | Assets, localization |
| `workers/src/` | The Worker API — the only thing that touches D1 |
| `workers/migrations/` | Ordered SQL migrations — the only way schema changes |
| `workers/authz/` | The authorization layer — every access decision lives here |
| `workers/test/` | The adversarial matrix. D1 has no RLS; this is what replaces it |
| `workers/scripts/` | `verify-schema.sh` — constraint and index checks |
| `admin/` | Next.js moderation console — server-side privileged access only |
| `docs/` | Product spec, architecture, database, design system |
| `Config/` | xcconfig build settings per environment |

Feature directories are **synchronized file system groups**. Adding a `.swift` file
inside `MyMiracles/` puts it in the build automatically — no `.xcodeproj` edit needed.

---

## Environments

Three build configurations map to three separate Cloudflare environments, each with its
own D1 database and R2 bucket. Never point a debug build at production data.

| Configuration | Environment | Bundle ID | Cloudflare environment |
|---|---|---|---|
| `Debug` | development | `com.mymiracles.MyMiracles.dev` | local `wrangler dev` + local D1 |
| `Staging` | staging | `com.mymiracles.MyMiracles.staging` | staging Worker + `my-miracles-staging` |
| `Release` | production | `com.mymiracles.MyMiracles` | production Worker + `my-miracles` |

Per-machine overrides live in `Config/Secrets.<Configuration>.xcconfig`, which is
**gitignored**. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.Debug.xcconfig`.
Each configuration includes only its own file, so the environments cannot point at the
same backend by accident.

The only thing configured is the API base URL. **No credential ships in the app.**
`AppConfiguration.load` scans the whole Info.plist and refuses to launch if it finds
anything credential-shaped, and it rejects plaintext HTTP outside development — rule 4 is
enforced at runtime, not just in review.

Server secrets — the session signing key, APNs credentials, the RevenueCat webhook secret
— are Worker secrets set with `wrangler secret put`, never files in this repository.

A literal `//` starts a comment in xcconfig, so URLs are composed with `$(MM_SLASH)`:

```
MM_API_BASE_URL = https:$(MM_SLASH)$(MM_SLASH)api.mymiracles.app
```

---

## Security invariants that must never regress

These are the rules a reviewer should check first, because a failure here is far worse
for this product than a crash:

- A client build holds no backend credential, and no client ever reaches D1 directly.
- Every Worker route authorizes explicitly before it reads or writes. D1 has no RLS, so a
  missing check has no second line of defence. Routes ask `src/authz/policy.ts`; they never
  re-derive a decision.
- A response is built by an explicit serializer, never by spreading a database row.
  `PostRecord` carries `ownerId`; `PostView` must not.
- Refusing something the viewer cannot see returns 404, not 403 — a 403 confirms the
  resource exists.
- `post_authorship` is never readable in a way that lets one user resolve the author of
  another user's anonymous post.
- A blocked relationship overrides every visibility rule, including `public`.
- Analytics events carry structured facts (type, visibility, bucketed counts) and never
  user-authored text. Enforce this in the type system, not by convention — see
  [`Core/Analytics`](MyMiracles/Core/Analytics).
- Push payloads default to generic copy. Prayer and journal text never appears on a lock
  screen unless the user explicitly opts in.
- Logging redacts user-authored content and identifiers by default.
- An Apple identity token is verified for signature, issuer, **audience**, expiry and nonce
  before it authenticates anyone. Dropping the audience check would let a token minted for
  another app sign someone in.
- Refresh tokens are single-use and stored only as a SHA-256 hash. A token presented twice
  revokes the whole chain — so the client must coalesce concurrent refreshes, or it will
  sign people out of their own accounts.

---

## Product invariants

- Prayer is never behind a paywall. Paying never ranks a user higher, boosts a prayer,
  or implies a better outcome.
- The journal is private by default. Sharing is always an explicit act.
- The user decides what counts as a miracle. The app supplies the container, not the
  theology.
- Sessions are finite. There is a "you're caught up" state; there is no infinite feed.
