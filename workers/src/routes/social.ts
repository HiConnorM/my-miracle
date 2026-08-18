import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { hidden, invalid, json, noContent } from '../http/responses';
import { pageLimit, readJson, requireString } from '../http/body';
import { areBlocked } from '../authz/policy';
import { formatCursor, listProfileTimeline, parseCursor, prayedPostIds } from '../db/posts';
import { serializePost } from '../db/types';
import { now } from '../db/ids';

interface ProfileRow {
  account_id: string;
  username: string;
  display_name: string;
  avatar_key: string | null;
  bio: string | null;
  created_at: number;
}

async function findProfileByUsername(
  env: RouteContext['env'],
  username: string,
): Promise<ProfileRow | null> {
  return env.DB.prepare(
    `select account_id, username, display_name, avatar_key, bio, created_at
     from profiles where username = ?`,
  )
    .bind(username.toLowerCase())
    .first<ProfileRow>();
}

/**
 * A public profile.
 *
 * A block makes the profile invisible in both directions — 404, not 403, so neither party
 * can use this endpoint to confirm the other still exists.
 *
 * Note what is absent: follower and following counts. There are no public popularity
 * metrics at launch (rule 13) — a prayer request is not more deserving because someone has
 * more followers.
 */
export async function getProfile({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const profile = await findProfileByUsername(env, params.username!);
  if (!profile) throw hidden();
  if (await areBlocked(env, viewer.accountId, profile.account_id)) throw hidden();

  const following = await env.DB.prepare(
    `select 1 as present from follows
     where follower_id = ? and followee_id = ? and state = 'accepted'`,
  )
    .bind(viewer.accountId, profile.account_id)
    .first<{ present: number }>();

  return json({
    username: profile.username,
    displayName: profile.display_name,
    avatarKey: profile.avatar_key,
    bio: profile.bio,
    createdAt: profile.created_at,
    isMe: profile.account_id === viewer.accountId,
    isFollowing: following !== null,
  });
}

export async function getProfileTimeline({
  request,
  env,
  params,
  url,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const profile = await findProfileByUsername(env, params.username!);
  if (!profile) throw hidden();
  if (await areBlocked(env, viewer.accountId, profile.account_id)) throw hidden();

  const posts = await listProfileTimeline(
    env,
    viewer,
    profile.account_id,
    parseCursor(url.searchParams.get('cursor')),
    pageLimit(url),
  );
  const prayed = await prayedPostIds(env, viewer, posts.map((post) => post.id));

  return json({
    items: posts.map((post) =>
      serializePost(post, {
        viewerAccountId: viewer.accountId,
        hasPrayed: prayed.has(post.id),
      }),
    ),
    nextCursor: posts.length > 0 ? formatCursor(posts[posts.length - 1]!) : null,
  });
}

export async function followProfile({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const body = await readJson(request);
  const username = requireString(body, 'username', { max: 24 });

  const profile = await findProfileByUsername(env, username);
  if (!profile) throw hidden();
  if (profile.account_id === viewer.accountId) throw invalid('you cannot follow yourself');
  // A blocked person cannot follow their way back in.
  if (await areBlocked(env, viewer.accountId, profile.account_id)) throw hidden();

  const timestamp = now();
  await env.DB.prepare(
    `insert into follows (follower_id, followee_id, state, created_at, updated_at)
     values (?, ?, 'accepted', ?, ?)
     on conflict (follower_id, followee_id) do nothing`,
  )
    .bind(viewer.accountId, profile.account_id, timestamp, timestamp)
    .run();

  return json({ following: true });
}

export async function unfollowProfile({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const profile = await findProfileByUsername(env, params.username!);
  if (!profile) throw hidden();

  await env.DB.prepare('delete from follows where follower_id = ? and followee_id = ?')
    .bind(viewer.accountId, profile.account_id)
    .run();

  return json({ following: false });
}

/**
 * Blocks somebody.
 *
 * Also tears down any follow relationship in **both** directions. Leaving a follow edge in
 * place after a block would mean the blocked person still counted as a follower, and
 * follower-only content would keep being generated for someone who can no longer see it.
 */
export async function createBlock({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const body = await readJson(request);
  const username = requireString(body, 'username', { max: 24 });

  const profile = await findProfileByUsername(env, username);
  if (!profile) throw hidden();
  if (profile.account_id === viewer.accountId) throw invalid('you cannot block yourself');

  await env.DB.batch([
    env.DB.prepare(
      `insert into blocks (blocker_id, blocked_id, created_at) values (?, ?, ?)
       on conflict (blocker_id, blocked_id) do nothing`,
    ).bind(viewer.accountId, profile.account_id, now()),
    env.DB.prepare(
      `delete from follows
       where (follower_id = ?1 and followee_id = ?2) or (follower_id = ?2 and followee_id = ?1)`,
    ).bind(viewer.accountId, profile.account_id),
  ]);

  return json({ blocked: true });
}

export async function deleteBlock({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const profile = await findProfileByUsername(env, params.username!);
  if (!profile) throw hidden();

  await env.DB.prepare('delete from blocks where blocker_id = ? and blocked_id = ?')
    .bind(viewer.accountId, profile.account_id)
    .run();

  return noContent();
}
