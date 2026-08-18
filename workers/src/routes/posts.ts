import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { conflict, invalid, json, noContent } from '../http/responses';
import {
  optionalBoolean,
  pageLimit,
  readJson,
  requireEnum,
  requireNumber,
  requireString,
} from '../http/body';
import { canViewPost, loadOwnedPost, loadViewablePost } from '../authz/policy';
import {
  findPost,
  formatCursor,
  hasPrayed,
  listPublicFeed,
  parseCursor,
  prayedPostIds,
} from '../db/posts';
import {
  POST_TYPES,
  POST_VISIBILITIES,
  serializePost,
  type PostRecord,
  type PostVisibility,
} from '../db/types';
import { now, uuidv7 } from '../db/ids';
import { idempotencyKey, recordKeyStatement, replayResult } from '../db/idempotency';
import type { Env } from '../env';
import type { Viewer } from '../auth/context';

async function page(env: Env, viewer: Viewer, posts: PostRecord[]) {
  const prayed = await prayedPostIds(env, viewer, posts.map((post) => post.id));
  return {
    items: posts.map((post) =>
      serializePost(post, {
        viewerAccountId: viewer.accountId,
        hasPrayed: prayed.has(post.id),
      }),
    ),
    nextCursor: posts.length > 0 ? formatCursor(posts[posts.length - 1]!) : null,
  };
}

export async function getPost({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadViewablePost(env, viewer, params.id!);

  return json({
    ...serializePost(post, {
      viewerAccountId: viewer.accountId,
      hasPrayed: await hasPrayed(env, viewer, post.id),
    }),
    link: await resolveAnsweredLink(env, viewer, post),
  });
}

/**
 * The other half of an answered story: the miracle a prayer became, or the prayer a
 * miracle came from.
 *
 * Resolved through the same visibility rules as anything else. A public prayer can be
 * answered with a private miracle, and in that case the link simply is not there — the
 * existence of an answer must not leak content the viewer cannot see.
 */
async function resolveAnsweredLink(
  env: Env,
  viewer: Viewer,
  post: PostRecord,
): Promise<{ id: string; type: string; excerpt: string; createdAt: number } | null> {
  const column = post.type === 'prayer' ? 'prayer_post_id' : 'miracle_post_id';
  const other = post.type === 'prayer' ? 'miracle_post_id' : 'prayer_post_id';

  const row = await env.DB.prepare(
    `select ${other} as linked_id from answered_links where ${column} = ?`,
  )
    .bind(post.id)
    .first<{ linked_id: string }>();
  if (!row) return null;

  const linked = await findPost(env, row.linked_id);
  if (!linked || !(await canViewPost(env, viewer, linked))) return null;

  return {
    id: linked.id,
    type: linked.type,
    excerpt: linked.body.length > 140 ? `${linked.body.slice(0, 139)}…` : linked.body,
    createdAt: linked.createdAt,
  };
}

export async function getFeed({ request, env, url }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const posts = await listPublicFeed(
    env,
    viewer,
    parseCursor(url.searchParams.get('cursor')),
    pageLimit(url),
  );
  return json(await page(env, viewer, posts));
}

export async function createPost({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const key = idempotencyKey(request);

  const replayed = await replayResult(env, viewer, key, 'create_post');
  if (replayed) {
    const existing = await findPost(env, replayed);
    if (existing) {
      return json(
        serializePost(existing, { viewerAccountId: viewer.accountId, hasPrayed: false }),
        200,
      );
    }
  }

  const body = await readJson(request);
  const type = requireEnum(body, 'type', POST_TYPES);
  const text = requireString(body, 'body', { max: 5000 });
  const visibility = requireEnum<PostVisibility>(body, 'visibility', POST_VISIBILITIES);
  const anonymous = optionalBoolean(body, 'anonymous');

  // A private post has no audience, so "anonymous" would be meaningless — and the schema
  // rejects it. Fail here with an explanation rather than surfacing a constraint error.
  if (anonymous && visibility === 'private') {
    throw invalid('a private post cannot also be anonymous');
  }

  const id = uuidv7();
  const timestamp = now();
  // NULL display profile is what makes a post anonymous to readers. The author is
  // recorded in post_authorship, which no route returns.
  const displayProfileId = anonymous ? null : viewer.accountId;

  await env.DB.batch([
    env.DB.prepare(
      `insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at)
       values (?, ?, ?, ?, 'active', ?, ?, ?)`,
    ).bind(id, type, text, visibility, displayProfileId, timestamp, timestamp),
    env.DB.prepare(
      'insert into post_authorship (post_id, owner_id, created_at) values (?, ?, ?)',
    ).bind(id, viewer.accountId, timestamp),
    ...recordKeyStatement(env, viewer, key, 'create_post', id),
  ]);

  const created = await findPost(env, id);
  return json(
    serializePost(created!, { viewerAccountId: viewer.accountId, hasPrayed: false }),
    201,
  );
}

export async function updatePost({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadOwnedPost(env, viewer, params.id!);

  const body = await readJson(request);
  const expectedVersion = requireNumber(body, 'version');
  // Optimistic concurrency. Someone may be editing the same entry on a phone and an iPad;
  // the second write must be told it is stale rather than silently discarding the first.
  if (expectedVersion !== post.version) {
    throw conflict('this post changed somewhere else');
  }

  const text = requireString(body, 'body', { max: 5000 });
  const visibility = requireEnum<PostVisibility>(body, 'visibility', POST_VISIBILITIES);

  // Making a post private requires a display profile, since anonymity and privacy are
  // mutually exclusive in the schema.
  const displayProfileId =
    visibility === 'private' ? viewer.accountId : post.displayProfileId;

  await env.DB.prepare(
    `update posts
     set body = ?, visibility = ?, display_profile_id = ?, updated_at = ?, version = version + 1
     where id = ? and version = ?`,
  )
    .bind(text, visibility, displayProfileId, now(), post.id, expectedVersion)
    .run();

  const updated = await findPost(env, post.id);
  return json(
    serializePost(updated!, {
      viewerAccountId: viewer.accountId,
      hasPrayed: await hasPrayed(env, viewer, post.id),
    }),
  );
}

/**
 * Deletes a post the viewer owns.
 *
 * A hard delete: foreign keys cascade to authorship, media, updates, prayer responses and
 * comments. Someone's journal is theirs, and "delete" should mean it.
 *
 * Phase 9 revisits retention when an open moderation case references the post — evidence
 * for an active report should outlive the reported user's delete button.
 */
export async function deletePost({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadOwnedPost(env, viewer, params.id!);

  await env.DB.prepare('delete from posts where id = ?').bind(post.id).run();
  return noContent();
}
