-- Staff.
--
-- Moderation is not a user permission. It is a separate grant, recorded in its own table,
-- so nothing about being a normal account can ever accumulate into moderator access — and
-- so revoking it is one delete.
--
-- Every moderation route requires a valid session **and** a row here. Attribution is real:
-- the audit trail records which account acted, not "the admin console".

create table staff (
  account_id text    not null primary key references accounts (id) on delete cascade,
  role       text    not null check (role in ('moderator', 'admin')),
  created_at integer not null,
  -- Who granted it. Access is itself an auditable event.
  granted_by text    references accounts (id) on delete set null
) strict;

create index staff_role on staff (role);

-- The moderator's queue: unresolved cases, most serious first.
create index moderation_cases_open on moderation_cases (state, risk desc, created_at asc)
  where state in ('open', 'triage');

-- "What has this person done before?" — the history a moderator needs before deciding.
create index moderation_actions_actor on moderation_actions (actor_id, created_at desc);
create index reports_reporter on reports (reporter_id, created_at desc);

-- Content removed by moderation, and accounts suspended, need a reason a person can read.
alter table posts add column removed_reason text;
alter table accounts add column suspension_reason text;
