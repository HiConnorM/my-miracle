import type { Env } from '../env';
import type { Viewer } from '../auth/context';
import { toPostRecord, type PostRecord, type PostRow } from './types';

/**
 * Explicit column list. There is no `select *` anywhere in this codebase — a schema change
 * must never silently start returning a new column to clients.
 *
 * `post_authorship` is joined because authorization needs the owner, and for an anonymous
 * post it is the only way to know who may edit it. The join stops at the Worker boundary;
 * see `serializePost`.
 */
const POST_COLUMNS = `
  p.id, p.type, p.body, p.visibility, p.status, p.display_profile_id,
  p.created_at, p.updated_at, p.answered_at, p.version,
  p.prayer_response_count, p.comment_count, p.update_count,
  a.owner_id as owner_id,
  dp.username as display_username,
  dp.display_name as display_name,
  dp.avatar_key as display_avatar_key
`;

const POST_FROM = `
  from posts p
  join post_authorship a on a.post_id = p.id
  left join profiles dp on dp.account_id = p.display_profile_id
`;

/**
 * Excludes anything either party has blocked, in both directions.
 *
 * This lives in SQL rather than as a filter over results, because post-filtering a page
 * would silently shrink it and leak the existence of blocked content through the gap.
 */
const NOT_BLOCKED = `
  not exists (
    select 1 from blocks b
    where (b.blocker_id = ?1 and b.blocked_id = a.owner_id)
       or (b.blocker_id = a.owner_id and b.blocked_id = ?1)
  )
`;

export interface Cursor {
  createdAt: number;
  id: string;
}

export function parseCursor(raw: string | null): Cursor | null {
  if (!raw) return null;
  const [createdAt, id] = raw.split(':');
  if (!createdAt || !id) return null;
  const parsed = Number(createdAt);
  return Number.isFinite(parsed) ? { createdAt: parsed, id } : null;
}

export function formatCursor(post: PostRecord): string {
  return `${post.createdAt}:${post.id}`;
}

export async function findPost(env: Env, postId: string): Promise<PostRecord | null> {
  const row = await env.DB.prepare(`select ${POST_COLUMNS} ${POST_FROM} where p.id = ?`)
    .bind(postId)
    .first<PostRow>();
  return row ? toPostRecord(row) : null;
}

/**
 * The public feed. Keyset paginated — never `OFFSET`, which gets more expensive the
 * further someone scrolls and skips rows when content is inserted mid-scroll.
 */
export async function listPublicFeed(
  env: Env,
  viewer: Viewer,
  cursor: Cursor | null,
  limit: number,
): Promise<PostRecord[]> {
  const keyset = cursor ? 'and (p.created_at, p.id) < (?2, ?3)' : '';
  const statement = env.DB.prepare(`
    select ${POST_COLUMNS} ${POST_FROM}
    where p.visibility = 'public'
      and p.status in ('active', 'answered')
      and ${NOT_BLOCKED}
      ${keyset}
    order by p.created_at desc, p.id desc
    limit ${cursor ? '?4' : '?2'}
  `);

  const bound = cursor
    ? statement.bind(viewer.accountId, cursor.createdAt, cursor.id, limit)
    : statement.bind(viewer.accountId, limit);

  const { results } = await bound.all<PostRow>();
  return results.map(toPostRecord);
}

/**
 * Someone's public profile timeline.
 *
 * Filtered on `display_profile_id`, **not** on authorship. That is what keeps anonymous
 * posts off their author's profile — the whole point of posting anonymously is that this
 * page does not list it.
 */
export async function listProfileTimeline(
  env: Env,
  viewer: Viewer,
  profileAccountId: string,
  cursor: Cursor | null,
  limit: number,
): Promise<PostRecord[]> {
  const isSelf = profileAccountId === viewer.accountId;
  // Visitors see public posts. Accepted followers additionally see follower-only posts.
  // Private posts appear only on your own profile.
  const visibility = isSelf
    ? `p.visibility in ('private', 'followers', 'public')`
    : `(p.visibility = 'public' or (p.visibility = 'followers' and exists (
          select 1 from follows f
          where f.follower_id = ?1 and f.followee_id = ?5 and f.state = 'accepted'
       )))`;

  const keyset = cursor ? 'and (p.created_at, p.id) < (?2, ?3)' : '';
  const statement = env.DB.prepare(`
    select ${POST_COLUMNS} ${POST_FROM}
    where p.display_profile_id = ?5
      and p.status <> 'removed'
      and ${visibility}
      and ${NOT_BLOCKED}
      ${keyset}
    order by p.created_at desc, p.id desc
    limit ${cursor ? '?4' : '?2'}
  `);

  const bound = cursor
    ? statement.bind(viewer.accountId, cursor.createdAt, cursor.id, limit, profileAccountId)
    : statement.bind(viewer.accountId, limit, null, null, profileAccountId);

  const { results } = await bound.all<PostRow>();
  return results.map(toPostRecord);
}

export async function hasPrayed(env: Env, viewer: Viewer, postId: string): Promise<boolean> {
  const row = await env.DB.prepare(
    'select 1 as present from prayer_responses where post_id = ? and account_id = ?',
  )
    .bind(postId, viewer.accountId)
    .first<{ present: number }>();
  return row !== null;
}

export async function prayedPostIds(
  env: Env,
  viewer: Viewer,
  postIds: string[],
): Promise<Set<string>> {
  if (postIds.length === 0) return new Set();
  const placeholders = postIds.map(() => '?').join(', ');
  const { results } = await env.DB.prepare(
    `select post_id from prayer_responses where account_id = ? and post_id in (${placeholders})`,
  )
    .bind(viewer.accountId, ...postIds)
    .all<{ post_id: string }>();
  return new Set(results.map((row) => row.post_id));
}
