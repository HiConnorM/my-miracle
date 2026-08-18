import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { conflict, invalid, json } from '../http/responses';
import { pageLimit, readJson, requireString } from '../http/body';
import { loadOwnedPost, loadViewablePost } from '../authz/policy';
import { findPost, hasPrayed } from '../db/posts';
import { serializePost } from '../db/types';
import { now, uuidv7 } from '../db/ids';
import { idempotencyKey, recordKeyStatement, replayResult } from '../db/idempotency';

/**
 * Updates posted while a prayer is still open.
 *
 * This is the "what happened next" that keeps a story alive between the request and the
 * answer — and the reason someone who prayed weeks ago comes back.
 */
export async function listPostUpdates({
  request,
  env,
  params,
  url,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadViewablePost(env, viewer, params.id!);

  const { results } = await env.DB.prepare(
    'select id, body, created_at from post_updates where post_id = ? order by created_at asc limit ?',
  )
    .bind(post.id, pageLimit(url))
    .all<{ id: string; body: string; created_at: number }>();

  return json({
    items: results.map((row) => ({ id: row.id, body: row.body, createdAt: row.created_at })),
  });
}

export async function createPostUpdate({
  request,
  env,
  params,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const post = await loadOwnedPost(env, viewer, params.id!);

  if (post.type !== 'prayer') {
    throw invalid('only a prayer can have updates');
  }

  const body = await readJson(request);
  const text = requireString(body, 'body', { max: 2000 });

  const id = uuidv7();
  const timestamp = now();

  await env.DB.batch([
    env.DB.prepare(
      'insert into post_updates (id, post_id, body, created_at) values (?, ?, ?, ?)',
    ).bind(id, post.id, text, timestamp),
    env.DB.prepare(
      'update posts set update_count = update_count + 1, updated_at = ? where id = ?',
    ).bind(timestamp, post.id),
  ]);

  return json({ id, body: text, createdAt: timestamp }, 201);
}

/**
 * The heart of the product: a prayer becomes a miracle.
 *
 * Engineering rule 10 — this must be transactional. It is one D1 batch, so either all of
 * it happens or none of it does:
 *
 *   1. create the miracle post
 *   2. record its authorship
 *   3. link prayer → miracle
 *   4. mark the prayer answered
 *   5. notify everyone who prayed
 *
 * A partial failure here would be quietly awful. A prayer marked answered with no miracle
 * would break the story; a miracle with no link would orphan it; notifications sent
 * without the link committed would tell people a prayer was answered and then show them
 * nothing. The database enforces the invariants twice over — `answered_links` has the
 * prayer as its primary key and the miracle uniquely indexed — so a prayer resolves once
 * and a miracle has exactly one origin, even if this code is wrong.
 */
export async function answerPrayer({ request, env, params }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const key = idempotencyKey(request);

  const replayed = await replayResult(env, viewer, key, 'answer_prayer');
  if (replayed) {
    const existing = await findPost(env, replayed);
    if (existing) {
      return json(
        serializePost(existing, { viewerAccountId: viewer.accountId, hasPrayed: false }),
        200,
      );
    }
  }

  const prayer = await loadOwnedPost(env, viewer, params.id!);

  if (prayer.type !== 'prayer') {
    throw invalid('only a prayer can be answered');
  }
  if (prayer.status === 'answered') {
    throw conflict('this prayer has already been answered');
  }
  if (prayer.status !== 'active') {
    throw invalid('only an open prayer can be answered');
  }

  const body = await readJson(request);
  const miracleBody = requireString(body, 'body', { max: 5000 });

  // The miracle inherits the prayer's visibility and anonymity unless told otherwise. If
  // someone asked for prayer anonymously, publishing the answer under their name would
  // retroactively unmask the request.
  const visibility = typeof body.visibility === 'string' ? body.visibility : prayer.visibility;
  if (!['private', 'followers', 'public'].includes(visibility)) {
    throw invalid('visibility must be private, followers or public');
  }

  const anonymous =
    typeof body.anonymous === 'boolean' ? body.anonymous : prayer.displayProfileId === null;
  if (anonymous && visibility === 'private') {
    throw invalid('a private post cannot also be anonymous');
  }
  const displayProfileId = anonymous ? null : viewer.accountId;

  const miracleId = uuidv7();
  const timestamp = now();

  await env.DB.batch([
    env.DB.prepare(
      `insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at)
       values (?, 'miracle', ?, ?, 'active', ?, ?, ?)`,
    ).bind(miracleId, miracleBody, visibility, displayProfileId, timestamp, timestamp),

    env.DB.prepare(
      'insert into post_authorship (post_id, owner_id, created_at) values (?, ?, ?)',
    ).bind(miracleId, viewer.accountId, timestamp),

    env.DB.prepare(
      'insert into answered_links (prayer_post_id, miracle_post_id, created_at) values (?, ?, ?)',
    ).bind(prayer.id, miracleId, timestamp),

    env.DB.prepare(
      `update posts
       set status = 'answered', answered_at = ?, updated_at = ?, version = version + 1
       where id = ? and status = 'active'`,
    ).bind(timestamp, timestamp, prayer.id),

    // Closure for everyone who carried this. Written as INSERT…SELECT so the recipients are
    // read inside the same transaction — someone who prays a moment before the commit is
    // still told. The id is derived from the prayer and the recipient, which makes a retry
    // collide rather than double-notify.
    env.DB.prepare(
      `insert or ignore into notification_events
         (id, recipient_id, type, subject_type, subject_id, actor_id, group_key, state, created_at)
       select 'answered:' || ?1 || ':' || pr.account_id, pr.account_id, 'answered', 'post',
              ?1, ?2, 'answered:' || ?1, 'pending', ?3
       from prayer_responses pr
       where pr.post_id = ?1 and pr.account_id <> ?2`,
    ).bind(prayer.id, viewer.accountId, timestamp),

    ...recordKeyStatement(env, viewer, key, 'answer_prayer', miracleId),
  ]);

  const miracle = await findPost(env, miracleId);
  return json(
    serializePost(miracle!, {
      viewerAccountId: viewer.accountId,
      hasPrayed: await hasPrayed(env, viewer, miracleId),
    }),
    201,
  );
}
