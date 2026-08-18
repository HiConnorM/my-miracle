# My Miracles — Database

Cloudflare D1 (SQLite) is the server source of truth (rule 2). All changes happen through
ordered migrations in [`workers/migrations/`](../workers/migrations) (rule 20).

The database models **stories and relationships**, not screens.

## SQLite conventions

D1 is SQLite, not Postgres. The differences are load-bearing:

| Concern | Convention | Why |
|---|---|---|
| Identifiers | `text` holding a UUIDv7 string | v7 is time-ordered, so the primary key doubles as a keyset-pagination tiebreaker |
| Timestamps | `integer`, epoch **milliseconds** UTC | No timezone ambiguity, sorts natively, one representation from SQLite row to SwiftUI view |
| Booleans | `integer` with `check (x in (0,1))` | SQLite has no boolean type |
| Enums | `text` with a `check` constraint | SQLite has no enum type — the CHECK *is* the enum |
| Tables | `strict` | SQLite otherwise coerces silently; type drift is exactly the rot that hides for months |
| Junction tables | `without rowid` | Composite-key lookups are the whole access pattern |

Keep every `check` constraint in step with the TypeScript union types in the Worker. The
constraint is the last line of defence, not the first.

## Tables

22 tables, 33 explicit indexes.

| Table | Purpose | Important fields |
|---|---|---|
| `accounts` | Authentication root and lifecycle | `id`, `status`, `deleted_at` |
| `profiles` | Public-facing identity | `account_id`, `username`, `display_name`, `avatar_key`, `bio` |
| `auth_identities` | Sign in with Apple subjects | `provider`, `provider_subject`, `email` |
| `devices` | APNs destinations, revocation unit | `account_id`, `apns_token`, `environment` |
| `refresh_tokens` | Rotating sessions | `token_hash`, `expires_at`, `revoked_at`, `replaced_by` |
| `posts` | Client-visible content object | `type`, `body`, `visibility`, `status`, `display_profile_id`, `version` |
| `post_authorship` | **Private ownership mapping** | `post_id`, `owner_id`, `created_at` |
| `post_media` | R2 object metadata | `post_id`, `object_key`, `media_type` |
| `post_updates` | Updates while a prayer is open | `post_id`, `body` |
| `prayer_responses` | "I prayed" | `(post_id, account_id)` |
| `answered_links` | Prayer → miracle relationship | `prayer_post_id`, `miracle_post_id` |
| `comments` | Encouragement/support | `post_id`, `author_account_id`, `parent_comment_id`, `status` |
| `follows` | Social graph | `follower_id`, `followee_id`, `state` |
| `blocks` | Hard social boundary | `blocker_id`, `blocked_id` |
| `reports` | User reports | `reporter_id`, `subject_type`, `subject_id`, `category` |
| `moderation_cases` | Operational case | `risk`, `state`, `assigned_to` |
| `moderation_actions` | Append-only audit trail | `case_id`, `actor_id`, `action`, `reason_code` |
| `notification_events` | Durable notification source | `recipient_id`, `type`, `group_key`, `state` |
| `user_entitlements` | Server subscription snapshot | `entitlement`, `status`, `expires_at` |
| `mutation_keys` | Idempotency | `key`, `operation`, `result_ref` |
| `deletion_requests` | Account deletion lifecycle | `state`, `scheduled_for` |
| `event_outbox` | Async reliable jobs | `type`, `payload`, `attempts`, `next_attempt_at` |

No monetary transfer tables in V1 (rule 11).

## The anonymity split — the most important schema decision

**Do not do this:**

```text
posts
id
author_id
is_anonymous
```

Rows returned to clients would contain the supposedly anonymous author's ID. One overbroad
`select *`, one missed column filter, and the anonymity promise is gone — for content that
may involve illness, marriage, sexuality, money problems, addiction, death, or family
crisis.

**Do this:**

```text
posts
----------------
id
display_profile_id NULLABLE      ← NULL means anonymous to readers

post_authorship
----------------
post_id
owner_id                         ← real account, never joined into a response
created_at                       ← denormalized so the Journal is an index-only scan
```

For an anonymous prayer, `posts.display_profile_id` is `NULL` while the protected
ownership table still knows who created it. Anonymous to other users, never to the
platform (rules 8 and 9).

This matters more on D1 than it would on Postgres. With RLS, a policy would refuse the row
even if a query asked for it. Here, the only thing standing between an anonymous author and
exposure is that **their identity is not in the table being read**. That is why the split
is structural rather than a convention.

`verify-schema.sh` asserts that `posts` has no author column, so this cannot be undone by
accident.

## Authorization matrix

There is no RLS. The Worker enforces every row below, and the matrix is the specification
for that code (rules 5 and 6).

| Resource | Read | Create | Modify/Delete |
|---|---|---|---|
| `profiles` | Public fields only, subject to block behavior | Own profile | Own profile |
| public `posts` | Any authenticated viewer unless blocked/removed | Authenticated account | Owner |
| follower posts | Accepted followers + owner | Owner | Owner |
| private posts | Owner only | Owner | Owner |
| `post_authorship` | Ownership checks only; never in a response | Worker, inside the create transaction | Never by a client |
| `prayer_responses` | Aggregate count; identity exposure intentionally limited | Current account only; unique | Own response |
| `comments` | Only if the viewer can see the parent post | Any viewer allowed by parent rules | Own comment |
| `follows` | Own graph | Current account | Current account |
| `blocks` | Own block records | Current account | Current account |
| `reports` | Reporter sees own report status | Current account | Immutable |
| `moderation_cases` | **No client access at all** | Worker/admin only | Worker/admin only |
| `moderation_actions` | **No client access at all** | Worker/admin only | Append-only |
| `devices` | Own | Own | Own |
| `refresh_tokens` | Never exposed | Worker only | Worker only |
| `user_entitlements` | Own | RevenueCat webhook only | RevenueCat webhook only |

**Blocks take precedence over everything**, including follows and `public` visibility, and
they apply in both directions.

## The adversarial matrix

Visibility is a security matrix, not a happy path. These are implemented in
[`workers/test/authorization.test.ts`](../workers/test/authorization.test.ts) and
[`anonymity.test.ts`](../workers/test/anonymity.test.ts), and run on every pull request.
None of them may be made to pass by loosening a check (rule 6).

```text
Alice private prayer
→ Alice CAN read
→ Bob gets 404, and is not told it exists
→ it is absent from the feed and from Alice's profile timeline
→ it accepts no prayers and no comments

Alice followers-only prayer
→ accepted follower CAN read
→ stranger CANNOT
→ following in the wrong direction grants nothing

Alice blocks Bob
→ neither sees the other's public content
→ the block outranks an existing follow, and tears the follow edge down
→ neither appears in the other's feed
→ the profile itself 404s
→ Bob cannot follow his way back in
→ Bob's existing comments disappear from Alice's view

Anonymous prayer
→ Bob CAN read the post
→ Alice's account id appears in NO response body, on any route
→ her username appears nowhere the post is surfaced
→ it is absent from her public profile timeline
→ it is still hers in her own journal, still editable, still deletable
→ the comment thread does not identify her

Bob updates Alice's public post          → 403 (he can see it; existence is not a secret)
Bob updates Alice's private post         → 404 (he cannot see it; do not confirm it)
Bob deletes Alice's post                 → 403
Bob reads Alice's journal                → empty; the route has no account parameter
Bob prays for a post he cannot see       → 404
Bob comments on a post he cannot see     → 404
Bob deletes Alice's comment              → 404
Bob reports a post he cannot see         → 404 (or reporting becomes an existence oracle)
Bob reports the same post twice          → 409
Any client requests moderation_cases,
  post_authorship, refresh_tokens,
  user_entitlements, accounts            → 404; no route exists to authorize
Bob replays Alice's idempotency key      → 403; keys are bound to an account
Forged / wrong-key / expired token       → 401
Token payload swapped for another sub    → 401
Suspended account with a live token      → 401, immediately
Stale write (wrong version)              → 409, never a silent overwrite
```

**Still outstanding, and deliberately so:** refresh-token rotation and the "presented
twice → revoke the whole family" rule. The table and its hashing exist; the rotation flow
lands with Sign in with Apple in Phase 3.

Schema-level constraints are covered separately by
[`workers/scripts/verify-schema.sh`](../workers/scripts/verify-schema.sh) — 40 checks over
anonymity, content constraints, the core loop, identity, safety and cascades. It needs no
network, so run it in the tight loop.

## Where authorization lives

One module: [`workers/src/authz/policy.ts`](../workers/src/authz/policy.ts). Routes ask it;
they never re-derive a decision.

| Function | Answers |
|---|---|
| `areBlocked(a, b)` | Is either party blocking the other? |
| `canViewPost(viewer, post)` | Ownership, then removal, then blocks, then visibility |
| `loadViewablePost(...)` | The post, or 404 |
| `loadOwnedPost(...)` | The post, or 404 if invisible / 403 if not yours |
| `canRespondToPost(...)` | Seeing is not the same as being able to pray or comment |

The 404-versus-403 rule is the part most easily got wrong: **if the viewer cannot see the
resource, 404; if they can see it but may not act on it, 403.** A 403 on something hidden
would confirm it exists.

## Transactional operations

`prayer → answered → miracle` is one atomic D1 batch, never a sequence of unrelated
requests (rule 10):

```text
verify ownership → create miracle → insert answered_link
→ set prayer.status = 'answered', answered_at
→ enqueue notification_events for everyone who prayed
→ commit
```

`answered_links` enforces the invariant twice over: `prayer_post_id` is the primary key and
`miracle_post_id` is uniquely indexed, so a prayer resolves once and a miracle has one
origin story even if the application logic is wrong.

## Migrations

```bash
cd workers && npm run db:reset:local     # apply migrations + seed locally
```

```bash
workers/scripts/verify-schema.sh          # constraints, indexes, cascades
```

Migrations are append-only and must be backward compatible for one release, because a
deploy rolls out while the previous Worker version is still serving.

## Seed data

`workers/seed.sql` provides two accounts and enough content to exercise the matrix: a
public miracle, an anonymous public prayer, a private journal entry, and an answered prayer
linked to the miracle it became — plus the pending closure notification owed to the person
who prayed. Identifiers are fixed and timestamps derive from literal dates, so a seeded
database is identical on every machine.

**Never run the seed against staging or production.**
