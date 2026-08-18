-- Service tokens for the moderation console.
--
-- The admin runs server-side and needs a credential that outlives a 15-minute access
-- token. It is deliberately a *separate* credential type, not a long-lived user session:
--
--   • It only opens `/v1/moderation`. Presenting one anywhere else does nothing.
--   • It belongs to a named staff account, so the audit trail still says who acted.
--   • It is stored only as a SHA-256 hash, like a refresh token.
--   • It can be revoked without touching that person's own account.
--
-- Tokens are issued out of band (`wrangler d1 execute`) rather than through a route. There
-- is no endpoint that mints moderator credentials, because an endpoint that mints moderator
-- credentials is a target.

create table staff_tokens (
  id           text    not null primary key,
  account_id   text    not null references accounts (id) on delete cascade,
  -- What this token is for, so a leaked one can be traced to a deployment.
  label        text    not null,
  token_hash   text    not null,
  created_at   integer not null,
  expires_at   integer,
  last_used_at integer,
  revoked_at   integer
) strict;

create unique index staff_tokens_hash on staff_tokens (token_hash);
create index staff_tokens_account on staff_tokens (account_id);
