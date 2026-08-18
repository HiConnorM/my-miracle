-- Saved posts: a private bookmark list.
--
-- Deliberately **not** a "like". Nothing about saving is visible to the author or to
-- anyone else, there is no count, and it does not influence what surfaces on Home. It
-- exists so someone can keep a prayer in mind, not so a post can accumulate a score
-- (rule 13).
--
-- Visibility is re-checked on read. Saving something public does not grant permanent
-- access: if the author makes it private, deletes it, or blocks you, it disappears from
-- your list.

create table saved_posts (
  account_id text    not null references accounts (id) on delete cascade,
  post_id    text    not null references posts (id) on delete cascade,
  created_at integer not null,
  primary key (account_id, post_id)
) strict, without rowid;

-- "Things I saved", newest first.
create index saved_posts_account on saved_posts (account_id, created_at desc);

-- Profile search matches on the start of a username or display name. `like 'query%'` can
-- use an index when the collation is case-insensitive, which is what makes searching for
-- people cheap without a separate search table.
create index profiles_username_search on profiles (username collate nocase);
create index profiles_display_name_search on profiles (display_name collate nocase);
