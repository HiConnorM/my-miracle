import type { Env } from '../env';
import type { Viewer } from '../auth/context';
import { findPost } from '../db/posts';
import { forbidden, hidden } from '../http/responses';
import type { PostRecord } from '../db/types';

/**
 * The authorization layer.
 *
 * On Postgres this would be RLS: policies the database enforces no matter what the
 * application does. D1 has no equivalent, so these functions are the entire boundary. A
 * route that forgets to call one of them has no backstop.
 *
 * Two rules govern everything here:
 *
 *   1. Every decision is made in this file. Routes ask; they do not re-derive.
 *   2. A failing authorization test is never fixed by loosening a check (rule 6). If a
 *      test says Bob cannot see something, the answer is to fix the caller, not the
 *      policy.
 *
 * The matrix these implement is in docs/database.md.
 */

/** Blocks are mutual: neither party sees the other, whoever pressed the button. */
export async function areBlocked(env: Env, a: string, b: string): Promise<boolean> {
  if (a === b) return false;
  const row = await env.DB.prepare(
    `select 1 as present from blocks
     where (blocker_id = ?1 and blocked_id = ?2) or (blocker_id = ?2 and blocked_id = ?1)
     limit 1`,
  )
    .bind(a, b)
    .first<{ present: number }>();
  return row !== null;
}

export async function isAcceptedFollower(
  env: Env,
  followerId: string,
  followeeId: string,
): Promise<boolean> {
  const row = await env.DB.prepare(
    `select 1 as present from follows
     where follower_id = ? and followee_id = ? and state = 'accepted'`,
  )
    .bind(followerId, followeeId)
    .first<{ present: number }>();
  return row !== null;
}

export function isOwner(viewer: Viewer, post: PostRecord): boolean {
  return post.ownerId === viewer.accountId;
}

/**
 * Can this viewer see this post?
 *
 * Order matters. Ownership is checked first so someone never loses access to their own
 * writing; blocks are checked before visibility so a block overrides `public`.
 */
export async function canViewPost(
  env: Env,
  viewer: Viewer,
  post: PostRecord,
): Promise<boolean> {
  // Your own words are always yours, including posts you published anonymously and posts
  // moderation has removed — you should be able to see what happened to your own content.
  if (isOwner(viewer, post)) return true;

  // Removed content is gone for everyone else, whatever its visibility says.
  if (post.status === 'removed') return false;

  // A block outranks every visibility rule below, including `public`.
  if (await areBlocked(env, viewer.accountId, post.ownerId)) return false;

  switch (post.visibility) {
    case 'private':
      return false; // ownership was the only way in, and it already failed
    case 'followers':
      return isAcceptedFollower(env, viewer.accountId, post.ownerId);
    case 'public':
      return true;
  }
}

/**
 * Loads a post the viewer is allowed to see, or refuses.
 *
 * Refuses with 404 rather than 403. A 403 would confirm that a post with this id exists,
 * which for a private prayer is itself a disclosure.
 */
export async function loadViewablePost(
  env: Env,
  viewer: Viewer,
  postId: string,
): Promise<PostRecord> {
  const post = await findPost(env, postId);
  if (!post) throw hidden();
  if (!(await canViewPost(env, viewer, post))) throw hidden();
  return post;
}

/**
 * Loads a post the viewer owns, or refuses.
 *
 * The distinction from {@link loadViewablePost} is deliberate: if the viewer cannot see
 * the post at all they get 404 (do not confirm it exists), but if they can see it and
 * simply do not own it they get 403 (it exists, you may not change it). Collapsing these
 * into one status would either leak existence or confuse a legitimate client.
 */
export async function loadOwnedPost(
  env: Env,
  viewer: Viewer,
  postId: string,
): Promise<PostRecord> {
  const post = await loadViewablePost(env, viewer, postId);
  if (!isOwner(viewer, post)) throw forbidden('you do not own this post');
  return post;
}

/**
 * Whether the viewer may respond to a post — pray for it, or comment on it.
 *
 * Seeing something is not the same as being able to act on it: a private post is visible
 * to its owner but is not a place for interaction, and removed content accepts nothing.
 */
export async function canRespondToPost(
  env: Env,
  viewer: Viewer,
  post: PostRecord,
): Promise<boolean> {
  if (post.visibility === 'private') return false;
  if (post.status === 'removed' || post.status === 'archived') return false;
  return canViewPost(env, viewer, post);
}

export async function loadRespondablePost(
  env: Env,
  viewer: Viewer,
  postId: string,
): Promise<PostRecord> {
  const post = await loadViewablePost(env, viewer, postId);
  if (!(await canRespondToPost(env, viewer, post))) {
    throw forbidden('this post is not accepting responses');
  }
  return post;
}
