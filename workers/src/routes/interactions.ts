import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { json, noContent } from '../http/responses';
import { pageLimit, readJson, requireString } from '../http/body';
import { loadRespondablePost, loadViewablePost } from '../authz/policy';
import { now, uuidv7 } from '../db/ids';

/**
 * "I prayed."
 *
 * One per person per post, enforced by the primary key. The counter on `posts` is
 * maintained in the same batch as the response row, so it can never drift — and it is
 * only ever a count. There is no leaderboard and no ranking (rule 13).
 */
export async function createPrayerResponse({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadRespondablePost(env, viewer, params.id!);

  const existing = await env.DB.prepare(
    'select 1 as present from prayer_responses where post_id = ? and account_id = ?',
  )
    .bind(post.id, viewer.accountId)
    .first<{ present: number }>();

  // Praying twice is a no-op, not an error. A double tap on a flaky connection should not
  // surface a failure for something this gentle.
  if (existing) {
    return json({ prayerResponseCount: post.prayerResponseCount, hasPrayed: true });
  }

  const timestamp = now();
  await env.DB.batch([
    env.DB.prepare(
      'insert into prayer_responses (post_id, account_id, created_at) values (?, ?, ?)',
    ).bind(post.id, viewer.accountId, timestamp),
    env.DB.prepare(
      'update posts set prayer_response_count = prayer_response_count + 1 where id = ?',
    ).bind(post.id),
    // The owner learns someone prayed. Grouped into "12 people prayed for you today" by
    // the dispatcher in Phase 10, never sent one by one.
    env.DB.prepare(
      `insert into notification_events
         (id, recipient_id, type, subject_type, subject_id, actor_id, group_key, state, created_at)
       values (?, ?, 'prayed', 'post', ?, ?, ?, 'pending', ?)`,
    ).bind(
      uuidv7(),
      post.ownerId,
      post.id,
      viewer.accountId,
      `prayed:${post.id}`,
      timestamp,
    ),
  ]);

  return json({ prayerResponseCount: post.prayerResponseCount + 1, hasPrayed: true });
}

export async function deletePrayerResponse({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadViewablePost(env, viewer, params.id!);

  const result = await env.DB.prepare(
    'delete from prayer_responses where post_id = ? and account_id = ?',
  )
    .bind(post.id, viewer.accountId)
    .run();

  if (result.meta.changes > 0) {
    await env.DB.prepare(
      `update posts set prayer_response_count = max(prayer_response_count - 1, 0) where id = ?`,
    )
      .bind(post.id)
      .run();
  }

  return json({
    prayerResponseCount: Math.max(
      post.prayerResponseCount - (result.meta.changes > 0 ? 1 : 0),
      0,
    ),
    hasPrayed: false,
  });
}

interface CommentRow {
  id: string;
  body: string;
  created_at: number;
  author_account_id: string;
  username: string;
  display_name: string;
  avatar_key: string | null;
}

/**
 * Comments on a post.
 *
 * Gated on being able to see the parent post — if the post is hidden, so is every
 * conversation about it. Commenters are shown under their own name; that does not expose
 * an anonymous post's author, who is not among them.
 */
export async function listComments({
  request,
  env,
  params,
  url,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadViewablePost(env, viewer, params.id!);

  const { results } = await env.DB.prepare(
    `select c.id, c.body, c.created_at, c.author_account_id,
            pr.username, pr.display_name, pr.avatar_key
     from comments c
     join profiles pr on pr.account_id = c.author_account_id
     where c.post_id = ?1
       and c.status = 'active'
       and not exists (
         select 1 from blocks b
         where (b.blocker_id = ?2 and b.blocked_id = c.author_account_id)
            or (b.blocker_id = c.author_account_id and b.blocked_id = ?2)
       )
     order by c.created_at asc
     limit ?3`,
  )
    .bind(post.id, viewer.accountId, pageLimit(url))
    .all<CommentRow>();

  return json({
    items: results.map((row) => ({
      id: row.id,
      body: row.body,
      createdAt: row.created_at,
      isMine: row.author_account_id === viewer.accountId,
      author: {
        username: row.username,
        displayName: row.display_name,
        avatarKey: row.avatar_key,
      },
    })),
  });
}

export async function createComment({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadRespondablePost(env, viewer, params.id!);

  const body = await readJson(request);
  const text = requireString(body, 'body', { max: 2000 });

  const id = uuidv7();
  const timestamp = now();

  await env.DB.batch([
    env.DB.prepare(
      `insert into comments (id, post_id, author_account_id, body, status, created_at, updated_at)
       values (?, ?, ?, ?, 'active', ?, ?)`,
    ).bind(id, post.id, viewer.accountId, text, timestamp, timestamp),
    env.DB.prepare('update posts set comment_count = comment_count + 1 where id = ?').bind(
      post.id,
    ),
    env.DB.prepare(
      `insert into notification_events
         (id, recipient_id, type, subject_type, subject_id, actor_id, group_key, state, created_at)
       values (?, ?, 'comment', 'post', ?, ?, ?, 'pending', ?)`,
    ).bind(
      uuidv7(),
      post.ownerId,
      post.id,
      viewer.accountId,
      `comment:${post.id}`,
      timestamp,
    ),
  ]);

  return json({ id, body: text, createdAt: timestamp }, 201);
}

export async function deleteComment({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  // Scoped to the author in the lookup itself, so there is no path where a mistaken
  // query deletes somebody else's words.
  const comment = await env.DB.prepare(
    'select post_id from comments where id = ? and author_account_id = ?',
  )
    .bind(params.id!, viewer.accountId)
    .first<{ post_id: string }>();

  if (!comment) {
    // Not found and not yours are the same answer: confirming a comment exists that you
    // may not touch is a disclosure.
    return json({ error: 'not_found' }, 404);
  }

  await env.DB.batch([
    env.DB.prepare('delete from comments where id = ?').bind(params.id!),
    env.DB.prepare(
      'update posts set comment_count = max(comment_count - 1, 0) where id = ?',
    ).bind(comment.post_id),
  ]);

  return noContent();
}
