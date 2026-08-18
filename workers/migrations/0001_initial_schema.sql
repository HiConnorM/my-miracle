-- My Miracles — initial schema
--
-- Target: Cloudflare D1 (SQLite).
--
-- CONVENTIONS
--   Identifiers  TEXT holding a UUIDv7 string. v7 is time-ordered, so a primary key
--                doubles as a stable tiebreaker for keyset pagination.
--   Timestamps   INTEGER, epoch milliseconds UTC. No timezone ambiguity, sorts natively.
--   Booleans     INTEGER constrained to 0/1. SQLite has no boolean type.
--   Enums        TEXT with a CHECK constraint. SQLite has no enum type; the CHECK is the
--                enum, and it must be kept in step with the TypeScript union types.
--   STRICT       Every table is STRICT so SQLite rejects a value of the wrong type instead
--                of silently coercing it. This codebase will be heavily AI-assisted and
--                type drift is exactly the kind of rot that hides for months.
--
-- SECURITY MODEL
--   D1 has no row-level security. The iOS client never reaches this database — it talks
--   only to the Worker API, which is the single place authorization is decided. That
--   makes the Worker a chokepoint rather than a suggestion, but it also means a missing
--   check here has no second line of defence. Engineering rules 5 and 6 apply to the
--   Worker's authorization layer, and the adversarial matrix in docs/database.md must
--   pass before any feature ships.

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- The authentication root. Deliberately separate from `profiles`: an account exists from
-- the moment someone signs in with Apple, before they have chosen a username, and it
-- survives as a tombstone through deletion while the profile is erased.
create table accounts (
  id           text    not null primary key,
  status       text    not null default 'active'
                       check (status in ('active', 'suspended', 'deleted')),
  created_at   integer not null,
  updated_at   integer not null,
  suspended_at integer,
  deleted_at   integer
) strict;

create index accounts_status on accounts (status);

-- The publicly visible projection of an account. Everything a stranger may see about a
-- person lives here and nowhere else, so a query that builds a public response never has
-- to reach into `accounts`.
create table profiles (
  account_id   text    not null primary key references accounts (id) on delete cascade,
  username     text    not null,
  display_name text    not null,
  -- R2 object key. Never a signed URL — those expire and must be minted per request.
  avatar_key   text,
  bio          text,
  created_at   integer not null,
  updated_at   integer not null,

  -- Lowercase, 3–24 characters, letters/digits/underscore. `not glob '*[^a-z0-9_]*'`
  -- asserts no character outside the set appears anywhere in the string.
  check (length(username) between 3 and 24),
  check (username not glob '*[^a-z0-9_]*'),
  check (length(display_name) between 1 and 60),
  check (bio is null or length(bio) <= 300)
) strict;

create unique index profiles_username on profiles (username);

-- One row per external identity. Apple's `sub` is the stable subject; the email may be a
-- private-relay address and may legitimately be absent.
create table auth_identities (
  id                     text    not null primary key,
  account_id             text    not null references accounts (id) on delete cascade,
  provider               text    not null check (provider in ('apple', 'email')),
  provider_subject       text    not null,
  email                  text,
  email_is_private_relay integer not null default 0 check (email_is_private_relay in (0, 1)),
  created_at             integer not null,
  last_used_at           integer
) strict;

-- One identity per (provider, subject) globally — this is what stops two accounts from
-- claiming the same Apple ID.
create unique index auth_identities_subject on auth_identities (provider, provider_subject);
create index auth_identities_account on auth_identities (account_id);

-- APNs destinations. Also the unit a session can be revoked against, so someone can sign
-- out one phone without losing the others.
create table devices (
  id           text    not null primary key,
  account_id   text    not null references accounts (id) on delete cascade,
  apns_token   text    not null,
  environment  text    not null check (environment in ('sandbox', 'production')),
  os_version   text,
  app_version  text,
  created_at   integer not null,
  last_seen_at integer not null
) strict;

-- A token can only belong to one account: when a phone is handed to someone else, the
-- new registration takes the token and the old row is replaced, never duplicated.
create unique index devices_apns_token on devices (apns_token);
create index devices_account on devices (account_id);

-- Refresh tokens are stored as a SHA-256 hash. The token itself is never written down,
-- so a dump of this table cannot be replayed to impersonate anyone.
create table refresh_tokens (
  id          text    not null primary key,
  account_id  text    not null references accounts (id) on delete cascade,
  token_hash  text    not null,
  device_id   text    references devices (id) on delete set null,
  issued_at   integer not null,
  expires_at  integer not null,
  revoked_at  integer,
  -- Set when this token is rotated. A presented token that is already replaced signals
  -- theft, and the whole family should be revoked.
  replaced_by text    references refresh_tokens (id) on delete set null
) strict;

create unique index refresh_tokens_hash on refresh_tokens (token_hash);
create index refresh_tokens_account on refresh_tokens (account_id, expires_at);

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

-- The client-visible content object.
--
-- ANONYMITY: there is deliberately NO author column here. `display_profile_id` is who the
-- post is shown as, and NULL means anonymous. Real ownership lives in `post_authorship`.
-- A response built from this table cannot leak an anonymous author even if the query is
-- wrong, because the identity is not in the row. See engineering rules 8 and 9.
create table posts (
  id                    text    not null primary key,
  type                  text    not null
                                check (type in ('prayer', 'miracle', 'gratitude', 'testimony')),
  body                  text    not null,
  visibility            text    not null
                                check (visibility in ('private', 'followers', 'public')),
  status                text    not null default 'active'
                                check (status in ('active', 'answered', 'archived', 'removed')),
  display_profile_id    text    references profiles (account_id) on delete set null,
  created_at            integer not null,
  updated_at            integer not null,
  answered_at           integer,
  -- Optimistic concurrency. An update carrying a stale version is a conflict, not a
  -- silent overwrite of something the person wrote on another device.
  version               integer not null default 1,
  -- Denormalized counters. Maintained inside the same transaction as the row they count;
  -- never recomputed on read, never trusted from the client.
  prayer_response_count integer not null default 0 check (prayer_response_count >= 0),
  comment_count         integer not null default 0 check (comment_count >= 0),
  update_count          integer not null default 0 check (update_count >= 0),

  check (length(body) between 1 and 5000),
  -- A private post has no audience, so showing it "anonymously" is meaningless and would
  -- only create a confusing second way to represent the same thing.
  check (visibility <> 'private' or display_profile_id is not null),
  -- Only a prayer can be answered.
  check (status <> 'answered' or type = 'prayer'),
  check ((status = 'answered') = (answered_at is not null))
) strict;

-- Public feed: newest first, keyset paginated on (created_at, id). Partial so the index
-- holds only rows the feed can ever return.
create index posts_public_feed on posts (created_at desc, id desc)
  where visibility = 'public' and status in ('active', 'answered');

-- Follower feed and profile timelines.
create index posts_display_profile on posts (display_profile_id, created_at desc, id desc)
  where display_profile_id is not null;

create index posts_open_prayers on posts (created_at desc, id desc)
  where type = 'prayer' and status = 'active' and visibility = 'public';

-- Who really wrote a post. Kept in its own table so it is never selected by accident.
--
-- The Worker must treat this as a write-and-authorize table: it answers "is this account
-- the owner?" and "what are my own posts?", and it must never be joined into a response
-- that another user can see.
create table post_authorship (
  post_id    text    not null primary key references posts (id) on delete cascade,
  owner_id   text    not null references accounts (id) on delete cascade,
  -- Denormalized from posts.created_at purely so the Journal timeline is an index-only
  -- scan. It is written once, at creation, and never updated.
  created_at integer not null
) strict;

-- The Journal: everything I have ever recorded, newest first, without touching `posts`
-- until the page is resolved.
create index post_authorship_journal on post_authorship (owner_id, created_at desc, post_id desc);

create table post_media (
  id          text    not null primary key,
  post_id     text    not null references posts (id) on delete cascade,
  -- R2 object key.
  object_key  text    not null,
  media_type  text    not null check (media_type in ('image', 'audio', 'video')),
  width       integer,
  height      integer,
  duration_ms integer,
  byte_size   integer not null check (byte_size > 0),
  position    integer not null default 0,
  created_at  integer not null
) strict;

create unique index post_media_object_key on post_media (object_key);
create index post_media_post on post_media (post_id, position);

-- Updates posted while a prayer is still open — the "what happened next" that keeps a
-- story alive between the request and the answer.
create table post_updates (
  id         text    not null primary key,
  post_id    text    not null references posts (id) on delete cascade,
  body       text    not null check (length(body) between 1 and 2000),
  created_at integer not null
) strict;

create index post_updates_post on post_updates (post_id, created_at desc);

-- "I prayed." One per person per post — this is a presence signal, not a score, and it
-- must not be farmable.
create table prayer_responses (
  post_id    text    not null references posts (id) on delete cascade,
  account_id text    not null references accounts (id) on delete cascade,
  created_at integer not null,
  primary key (post_id, account_id)
) strict, without rowid;

-- "Prayers I have carried" — and the source for closure notifications when one is
-- answered.
create index prayer_responses_account on prayer_responses (account_id, created_at desc);

-- The heart of the product: a prayer and the miracle it became.
--
-- Both sides are unique. A prayer resolves once, and a miracle has one origin story.
create table answered_links (
  prayer_post_id  text    not null primary key references posts (id) on delete cascade,
  miracle_post_id text    not null references posts (id) on delete cascade,
  created_at      integer not null,
  check (prayer_post_id <> miracle_post_id)
) strict;

create unique index answered_links_miracle on answered_links (miracle_post_id);

create table comments (
  id                text    not null primary key,
  post_id           text    not null references posts (id) on delete cascade,
  author_account_id text    not null references accounts (id) on delete cascade,
  parent_comment_id text    references comments (id) on delete cascade,
  body              text    not null check (length(body) between 1 and 2000),
  status            text    not null default 'active'
                            check (status in ('active', 'removed')),
  created_at        integer not null,
  updated_at        integer not null
) strict;

create index comments_post on comments (post_id, created_at)
  where status = 'active';
create index comments_author on comments (author_account_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Social graph
-- ---------------------------------------------------------------------------

create table follows (
  follower_id text    not null references accounts (id) on delete cascade,
  followee_id text    not null references accounts (id) on delete cascade,
  state       text    not null default 'accepted'
                      check (state in ('pending', 'accepted')),
  created_at  integer not null,
  updated_at  integer not null,
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
) strict, without rowid;

create index follows_followee on follows (followee_id, state);

-- A hard boundary. Blocks override follows and override `public` visibility — see the
-- authorization matrix in docs/database.md. Enforced in the Worker on every read path,
-- not just at follow time.
create table blocks (
  blocker_id text    not null references accounts (id) on delete cascade,
  blocked_id text    not null references accounts (id) on delete cascade,
  created_at integer not null,
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
) strict, without rowid;

-- Needed because a block must hide content in BOTH directions, so lookups happen from
-- either side.
create index blocks_blocked on blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- Safety and moderation
-- ---------------------------------------------------------------------------

-- Operational record for something under review. No mobile client ever reads this table.
create table moderation_cases (
  id           text    not null primary key,
  subject_type text    not null check (subject_type in ('post', 'comment', 'profile')),
  subject_id   text    not null,
  risk         text    not null default 'low'
                       check (risk in ('low', 'medium', 'high', 'critical')),
  state        text    not null default 'open'
                       check (state in ('open', 'triage', 'actioned', 'dismissed')),
  assigned_to  text    references accounts (id) on delete set null,
  report_count integer not null default 0 check (report_count >= 0),
  created_at   integer not null,
  updated_at   integer not null,
  resolved_at  integer
) strict;

-- One open case per subject, so ten reports about the same post converge instead of
-- creating ten queue entries.
create unique index moderation_cases_open_subject on moderation_cases (subject_type, subject_id)
  where state in ('open', 'triage');
create index moderation_cases_queue on moderation_cases (state, risk, created_at);

create table reports (
  id           text    not null primary key,
  reporter_id  text    not null references accounts (id) on delete cascade,
  subject_type text    not null check (subject_type in ('post', 'comment', 'profile')),
  subject_id   text    not null,
  category     text    not null
                       check (category in ('harassment', 'sexual', 'graphic', 'spam',
                                           'scam', 'self_harm', 'impersonation',
                                           'medical_misinformation', 'privacy', 'other')),
  details      text    check (details is null or length(details) <= 1000),
  case_id      text    references moderation_cases (id) on delete set null,
  created_at   integer not null
) strict;

-- One report per person per subject. Report volume is a signal, but it is never a
-- verdict — brigading must not be able to manufacture guilt.
create unique index reports_unique_reporter on reports (reporter_id, subject_type, subject_id);
create index reports_subject on reports (subject_type, subject_id);
create index reports_case on reports (case_id);

-- Append-only audit trail. Staff never mutate content directly; every decision lands here
-- with who, what changed, and why.
create table moderation_actions (
  id             text    not null primary key,
  case_id        text    not null references moderation_cases (id) on delete cascade,
  actor_id       text    not null references accounts (id),
  action         text    not null
                         check (action in ('keep', 'warn', 'remove', 'restrict',
                                           'suspend', 'reinstate', 'escalate', 'assign')),
  reason_code    text    not null,
  previous_state text,
  new_state      text,
  evidence_ref   text,
  notes          text,
  created_at     integer not null
) strict;

create index moderation_actions_case on moderation_actions (case_id, created_at);

-- ---------------------------------------------------------------------------
-- Delivery and platform
-- ---------------------------------------------------------------------------

-- Durable source of truth for notifications. Rows are created inside the transaction that
-- causes them, then grouped and delivered asynchronously — twelve "I prayed" events
-- collapse into one "12 people prayed for you today".
create table notification_events (
  id           text    not null primary key,
  recipient_id text    not null references accounts (id) on delete cascade,
  type         text    not null
                       check (type in ('prayed', 'comment', 'answered', 'memory',
                                       'prayer_window', 'moderation')),
  subject_type text    not null check (subject_type in ('post', 'comment', 'profile')),
  subject_id   text    not null,
  actor_id     text    references accounts (id) on delete set null,
  -- Rows sharing a group_key collapse into a single push.
  group_key    text    not null,
  state        text    not null default 'pending'
                       check (state in ('pending', 'grouped', 'sent', 'suppressed', 'failed')),
  created_at   integer not null,
  sent_at      integer
) strict;

create index notification_events_pending on notification_events (state, created_at)
  where state = 'pending';
create index notification_events_group on notification_events (recipient_id, group_key, state);

-- Server-owned subscription state, written only by the RevenueCat webhook. The client
-- reports what it believes for UI purposes; the backend authorizes against this.
create table user_entitlements (
  account_id  text    not null primary key references accounts (id) on delete cascade,
  entitlement text    not null check (entitlement in ('free', 'plus', 'patron')),
  status      text    not null
                      check (status in ('active', 'grace', 'expired', 'billing_retry', 'paused')),
  product_id  text,
  expires_at  integer,
  updated_at  integer not null,
  source      text    not null default 'revenuecat'
) strict;

-- Idempotency. A phone that loses connection mid-write retries with the same key, and the
-- second attempt returns the first result instead of creating a duplicate prayer.
create table mutation_keys (
  key        text    not null primary key,
  account_id text    not null references accounts (id) on delete cascade,
  operation  text    not null,
  result_ref text,
  created_at integer not null
) strict;

create index mutation_keys_account on mutation_keys (account_id, created_at);

-- Account deletion lifecycle. Apple requires an in-app path to full deletion; the delay
-- window exists so an accidental tap is recoverable, not so we can keep the data.
create table deletion_requests (
  id            text    not null primary key,
  account_id    text    not null references accounts (id) on delete cascade,
  state         text    not null default 'scheduled'
                        check (state in ('scheduled', 'cancelled', 'processing', 'completed')),
  requested_at  integer not null,
  scheduled_for integer not null,
  completed_at  integer
) strict;

create unique index deletion_requests_pending on deletion_requests (account_id)
  where state in ('scheduled', 'processing');

-- Reliable async work: notification dispatch, media processing, webhook fan-out. Written
-- in the same transaction as the change that triggers it, drained by a Queue consumer.
create table event_outbox (
  id              text    not null primary key,
  type            text    not null,
  payload         text    not null,
  state           text    not null default 'pending'
                          check (state in ('pending', 'processing', 'done', 'dead')),
  attempts        integer not null default 0 check (attempts >= 0),
  next_attempt_at integer not null,
  last_error      text,
  created_at      integer not null,
  updated_at      integer not null
) strict;

create index event_outbox_ready on event_outbox (next_attempt_at)
  where state = 'pending';
create index event_outbox_dead on event_outbox (state, updated_at)
  where state = 'dead';
