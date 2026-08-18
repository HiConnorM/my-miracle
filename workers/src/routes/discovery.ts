import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { json, noContent } from '../http/responses';
import { pageLimit } from '../http/body';
import { loadViewablePost } from '../authz/policy';
import { formatCursor, parseCursor, prayedPostIds } from '../db/posts';
import { serializePost, toPostRecord, type PostRow } from '../db/types';
import { now } from '../db/ids';

/**
 * Saving, and finding people.
 *
 * The social half of the product, built without the mechanics that make social products
 * unpleasant. There are no follower counts, no popularity ranking, no trending, no
 * suggestions ordered by engagement, and no direct messages (rules 12 and 13).
 *
 * Discovery is a search box. Someone has to be looking for a person to find one.
 */

// MARK: - Saved posts

/**
 * Saves a post to a private list.
 *
 * Not a like: the author is never told, there is no count, and nothing about it feeds
 * ranking. It is a bookmark so someone can keep a prayer in mind.
 */
export async function savePost({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  // Must be visible to save. Otherwise saving becomes a way to probe for posts.
  const post = await loadViewablePost(env, viewer, params.id!);

  await env.DB.prepare(
    `insert into saved_posts (account_id, post_id, created_at) values (?, ?, ?)
     on conflict (account_id, post_id) do nothing`,
  )
    .bind(viewer.accountId, post.id, now())
    .run();

  return json({ saved: true });
}

export async function unsavePost({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  await env.DB.prepare('delete from saved_posts where account_id = ? and post_id = ?')
    .bind(viewer.accountId, params.id!)
    .run();

  return json({ saved: false });
}

/**
 * The private list of saved posts.
 *
 * **Visibility is re-checked here, every time.** Saving something does not grant permanent
 * access — if the author makes it private, removes it, or blocks the viewer, it drops out
 * of this list. A bookmark is a pointer, not a copy.
 */
export async function listSaved({ request, env, url }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const cursor = parseCursor(url.searchParams.get('cursor'));
  const limit = pageLimit(url);

  const keyset = cursor ? 'and (s.created_at, s.post_id) < (?2, ?3)' : '';
  const statement = env.DB.prepare(`
    select p.id, p.type, p.body, p.visibility, p.status, p.display_profile_id,
           p.created_at, p.updated_at, p.answered_at, p.version,
           p.prayer_response_count, p.comment_count, p.update_count,
           a.owner_id as owner_id,
           dp.username as display_username,
           dp.display_name as display_name,
           dp.avatar_key as display_avatar_key
    from saved_posts s
    join posts p on p.id = s.post_id
    join post_authorship a on a.post_id = p.id
    left join profiles dp on dp.account_id = p.display_profile_id
    where s.account_id = ?1
      and p.status <> 'removed'
      -- The same rules as anywhere else: your own, or public, or follower-only if you
      -- follow them. A block removes it outright.
      and (
        a.owner_id = ?1
        or p.visibility = 'public'
        or (p.visibility = 'followers' and exists (
              select 1 from follows f
              where f.follower_id = ?1 and f.followee_id = a.owner_id and f.state = 'accepted'
           ))
      )
      and not exists (
        select 1 from blocks b
        where (b.blocker_id = ?1 and b.blocked_id = a.owner_id)
           or (b.blocker_id = a.owner_id and b.blocked_id = ?1)
      )
      ${keyset}
    order by s.created_at desc, s.post_id desc
    limit ${cursor ? '?4' : '?2'}
  `);

  const bound = cursor
    ? statement.bind(viewer.accountId, cursor.createdAt, cursor.id, limit)
    : statement.bind(viewer.accountId, limit);

  const { results } = await bound.all<PostRow>();
  const posts = results.map(toPostRecord);
  const prayed = await prayedPostIds(env, viewer, posts.map((post) => post.id));

  return json({
    items: posts.map((post) =>
      serializePost(post, {
        viewerAccountId: viewer.accountId,
        hasPrayed: prayed.has(post.id),
      }),
    ),
    nextCursor: posts.length === limit && posts.length > 0
      ? `${posts[posts.length - 1]!.createdAt}:${posts[posts.length - 1]!.id}`
      : null,
  });
}

export async function savedPostIds(
  env: RouteContext['env'],
  accountId: string,
  postIds: string[],
): Promise<Set<string>> {
  if (postIds.length === 0) return new Set();
  const placeholders = postIds.map(() => '?').join(', ');
  const { results } = await env.DB.prepare(
    `select post_id from saved_posts where account_id = ? and post_id in (${placeholders})`,
  )
    .bind(accountId, ...postIds)
    .all<{ post_id: string }>();
  return new Set(results.map((row) => row.post_id));
}

// MARK: - Finding people

/**
 * People search.
 *
 * The whole of discovery. There is no ranked list of suggested accounts, no "people you may
 * know", and no trending — someone has to be looking for a person to find one, which is the
 * difference between a directory and a growth mechanic.
 *
 * Results carry **no follower count and no post count**. A prayer request is not more
 * deserving because the person asking has an audience (rule 13).
 */
export async function searchPeople({ request, env, url }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const query = (url.searchParams.get('q') ?? '').trim();

  // A single character matches most of a directory and helps nobody.
  if (query.length < 2) {
    return json({ items: [] });
  }

  const prefix = `${escapeLike(query.toLowerCase())}%`;
  const { results } = await env.DB.prepare(`
    select pr.account_id, pr.username, pr.display_name, pr.avatar_key, pr.bio,
           exists (
             select 1 from follows f
             where f.follower_id = ?1 and f.followee_id = pr.account_id and f.state = 'accepted'
           ) as following
    from profiles pr
    where pr.account_id <> ?1
      and (pr.username like ?2 escape '\\' or pr.display_name like ?2 escape '\\' collate nocase)
      -- A block hides a person from search in both directions.
      and not exists (
        select 1 from blocks b
        where (b.blocker_id = ?1 and b.blocked_id = pr.account_id)
           or (b.blocker_id = pr.account_id and b.blocked_id = ?1)
      )
      and exists (select 1 from accounts ac where ac.id = pr.account_id and ac.status = 'active')
    order by pr.username collate nocase asc
    limit ?3
  `)
    .bind(viewer.accountId, prefix, pageLimit(url, 20, 30))
    .all<{
      account_id: string;
      username: string;
      display_name: string;
      avatar_key: string | null;
      bio: string | null;
      following: number;
    }>();

  return json({
    items: results.map((row) => ({
      username: row.username,
      displayName: row.display_name,
      avatarKey: row.avatar_key,
      bio: row.bio,
      isFollowing: row.following === 1,
    })),
  });
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}

export { noContent };
