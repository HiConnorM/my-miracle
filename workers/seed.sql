-- My Miracles — local development seed.
--
-- Two accounts and exactly the content needed to exercise the visibility matrix:
--   • a public miracle
--   • an anonymous public prayer
--   • a private journal entry
--   • an answered prayer linked to the miracle it became
--
-- Identifiers are fixed so tests can reference them. Timestamps are derived from literal
-- dates, so a seeded database is byte-identical on every machine.
--
-- NEVER run this against staging or production.

delete from event_outbox;
delete from deletion_requests;
delete from mutation_keys;
delete from user_entitlements;
delete from notification_events;
delete from moderation_actions;
delete from reports;
delete from moderation_cases;
delete from blocks;
delete from follows;
delete from comments;
delete from answered_links;
delete from prayer_responses;
delete from post_updates;
delete from post_media;
delete from post_authorship;
delete from posts;
delete from refresh_tokens;
delete from devices;
delete from auth_identities;
delete from profiles;
delete from accounts;

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

insert into accounts (id, status, created_at, updated_at) values
  ('01930000-0000-7000-8000-00000000a001', 'active', unixepoch('2026-06-01T09:00:00Z') * 1000, unixepoch('2026-06-01T09:00:00Z') * 1000),
  ('01930000-0000-7000-8000-00000000b001', 'active', unixepoch('2026-06-03T18:30:00Z') * 1000, unixepoch('2026-06-03T18:30:00Z') * 1000);

insert into profiles (account_id, username, display_name, bio, created_at, updated_at) values
  ('01930000-0000-7000-8000-00000000a001', 'connor', 'Connor', 'Keeping track of the good.', unixepoch('2026-06-01T09:02:00Z') * 1000, unixepoch('2026-06-01T09:02:00Z') * 1000),
  ('01930000-0000-7000-8000-00000000b001', 'gabi',   'Gabi',   null,                          unixepoch('2026-06-03T18:32:00Z') * 1000, unixepoch('2026-06-03T18:32:00Z') * 1000);

insert into auth_identities (id, account_id, provider, provider_subject, email, email_is_private_relay, created_at, last_used_at) values
  ('01930000-0000-7000-8000-0000000a1001', '01930000-0000-7000-8000-00000000a001', 'apple', '000123.seedconnor.0001', 'connor@example.com',                 0, unixepoch('2026-06-01T09:00:00Z') * 1000, unixepoch('2026-08-17T07:15:00Z') * 1000),
  ('01930000-0000-7000-8000-0000000a1002', '01930000-0000-7000-8000-00000000b001', 'apple', '000123.seedgabi.0002',   'gabi@privaterelay.appleid.com',      1, unixepoch('2026-06-03T18:30:00Z') * 1000, unixepoch('2026-08-17T20:40:00Z') * 1000);

-- Gabi follows Connor, so follower-only content is exercised in one direction only.
insert into follows (follower_id, followee_id, state, created_at, updated_at) values
  ('01930000-0000-7000-8000-00000000b001', '01930000-0000-7000-8000-00000000a001', 'accepted', unixepoch('2026-06-04T08:00:00Z') * 1000, unixepoch('2026-06-04T08:00:00Z') * 1000);

-- ---------------------------------------------------------------------------
-- 1. A public miracle, shown under Connor's name
-- ---------------------------------------------------------------------------

insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at, prayer_response_count) values
  ('01930000-0000-7000-8000-00000000c001', 'miracle',
   'The car started on the third try, on the morning it absolutely had to.',
   'public', 'active', '01930000-0000-7000-8000-00000000a001',
   unixepoch('2026-07-02T14:20:00Z') * 1000, unixepoch('2026-07-02T14:20:00Z') * 1000, 0);

insert into post_authorship (post_id, owner_id, created_at) values
  ('01930000-0000-7000-8000-00000000c001', '01930000-0000-7000-8000-00000000a001', unixepoch('2026-07-02T14:20:00Z') * 1000);

-- ---------------------------------------------------------------------------
-- 2. An anonymous public prayer
--
-- display_profile_id is NULL, so nothing in `posts` identifies the author. Ownership is
-- only in post_authorship. Any query that can resolve Gabi from this post through the
-- API is a bug — see the adversarial matrix in docs/database.md.
-- ---------------------------------------------------------------------------

insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at, prayer_response_count) values
  ('01930000-0000-7000-8000-00000000c002', 'prayer',
   'Please pray for my marriage. We are trying, and it is hard right now.',
   'public', 'active', null,
   unixepoch('2026-07-28T21:05:00Z') * 1000, unixepoch('2026-07-28T21:05:00Z') * 1000, 1);

insert into post_authorship (post_id, owner_id, created_at) values
  ('01930000-0000-7000-8000-00000000c002', '01930000-0000-7000-8000-00000000b001', unixepoch('2026-07-28T21:05:00Z') * 1000);

insert into prayer_responses (post_id, account_id, created_at) values
  ('01930000-0000-7000-8000-00000000c002', '01930000-0000-7000-8000-00000000a001', unixepoch('2026-07-29T07:40:00Z') * 1000);

-- ---------------------------------------------------------------------------
-- 3. A private journal entry — visible to nobody but Connor
-- ---------------------------------------------------------------------------

insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at) values
  ('01930000-0000-7000-8000-00000000c003', 'gratitude',
   'Dad called for no reason at all today. We talked for an hour.',
   'private', 'active', '01930000-0000-7000-8000-00000000a001',
   unixepoch('2026-08-05T22:10:00Z') * 1000, unixepoch('2026-08-05T22:10:00Z') * 1000);

insert into post_authorship (post_id, owner_id, created_at) values
  ('01930000-0000-7000-8000-00000000c003', '01930000-0000-7000-8000-00000000a001', unixepoch('2026-08-05T22:10:00Z') * 1000);

-- ---------------------------------------------------------------------------
-- 4. The core loop: a prayer that was answered, and the miracle it became
-- ---------------------------------------------------------------------------

insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at, answered_at, prayer_response_count, update_count) values
  ('01930000-0000-7000-8000-00000000c004', 'prayer',
   'I have an interview on Thursday. It would change a lot for us.',
   'public', 'answered', '01930000-0000-7000-8000-00000000a001',
   unixepoch('2026-07-06T16:00:00Z') * 1000, unixepoch('2026-07-20T11:30:00Z') * 1000,
   unixepoch('2026-07-20T11:30:00Z') * 1000, 1, 1);

insert into post_authorship (post_id, owner_id, created_at) values
  ('01930000-0000-7000-8000-00000000c004', '01930000-0000-7000-8000-00000000a001', unixepoch('2026-07-06T16:00:00Z') * 1000);

insert into prayer_responses (post_id, account_id, created_at) values
  ('01930000-0000-7000-8000-00000000c004', '01930000-0000-7000-8000-00000000b001', unixepoch('2026-07-07T09:12:00Z') * 1000);

insert into post_updates (id, post_id, body, created_at) values
  ('01930000-0000-7000-8000-00000000d001', '01930000-0000-7000-8000-00000000c004',
   'It went well. They said they would call by the end of next week.',
   unixepoch('2026-07-09T19:45:00Z') * 1000);

insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at) values
  ('01930000-0000-7000-8000-00000000c005', 'miracle',
   'I got the call. I start on the first.',
   'public', 'active', '01930000-0000-7000-8000-00000000a001',
   unixepoch('2026-07-20T11:30:00Z') * 1000, unixepoch('2026-07-20T11:30:00Z') * 1000);

insert into post_authorship (post_id, owner_id, created_at) values
  ('01930000-0000-7000-8000-00000000c005', '01930000-0000-7000-8000-00000000a001', unixepoch('2026-07-20T11:30:00Z') * 1000);

insert into answered_links (prayer_post_id, miracle_post_id, created_at) values
  ('01930000-0000-7000-8000-00000000c004', '01930000-0000-7000-8000-00000000c005', unixepoch('2026-07-20T11:30:00Z') * 1000);

-- Gabi prayed for that prayer, so she is owed closure.
insert into notification_events (id, recipient_id, type, subject_type, subject_id, actor_id, group_key, state, created_at) values
  ('01930000-0000-7000-8000-0000000e0001', '01930000-0000-7000-8000-00000000b001', 'answered', 'post',
   '01930000-0000-7000-8000-00000000c004', '01930000-0000-7000-8000-00000000a001',
   'answered:01930000-0000-7000-8000-00000000c004', 'pending', unixepoch('2026-07-20T11:30:00Z') * 1000);

insert into comments (id, post_id, author_account_id, body, created_at, updated_at) values
  ('01930000-0000-7000-8000-0000000f0001', '01930000-0000-7000-8000-00000000c005', '01930000-0000-7000-8000-00000000b001',
   'I have been thinking about this all week. So glad.',
   unixepoch('2026-07-20T12:05:00Z') * 1000, unixepoch('2026-07-20T12:05:00Z') * 1000);

update posts set comment_count = 1 where id = '01930000-0000-7000-8000-00000000c005';

insert into user_entitlements (account_id, entitlement, status, updated_at) values
  ('01930000-0000-7000-8000-00000000a001', 'free', 'active', unixepoch('2026-06-01T09:00:00Z') * 1000),
  ('01930000-0000-7000-8000-00000000b001', 'free', 'active', unixepoch('2026-06-03T18:30:00Z') * 1000);
