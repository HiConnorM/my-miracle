import type { RouteContext } from '../http/router';
import { requireViewer, type Viewer } from '../auth/context';
import { json } from '../http/responses';
import { toPostRecord, serializePost, type PostRow } from '../db/types';
import { prayedPostIds } from '../db/posts';
import type { Env } from '../env';

/**
 * Home: a finite, intentional session.
 *
 * Deliberately **not** a feed. It returns a small, bounded set of people to pray for, a few
 * recent miracles, and possibly one memory — and it tells the client how many prayers
 * remain so the app can offer "see more" as a choice rather than scrolling forever.
 *
 * The whole screen is one request. Home is the first thing someone sees, and stitching it
 * from four round trips would make the calmest screen in the product the slowest.
 */

/** How many people to offer in one sitting. Small enough to finish. */
const PRAYER_BATCH = 5;
const RECENT_MIRACLES = 3;

const COLUMNS = `
  p.id, p.type, p.body, p.visibility, p.status, p.display_profile_id,
  p.created_at, p.updated_at, p.answered_at, p.version,
  p.prayer_response_count, p.comment_count, p.update_count,
  a.owner_id as owner_id,
  dp.username as display_username,
  dp.display_name as display_name,
  dp.avatar_key as display_avatar_key
`;

const FROM = `
  from posts p
  join post_authorship a on a.post_id = p.id
  left join profiles dp on dp.account_id = p.display_profile_id
`;

const NOT_BLOCKED = `
  not exists (
    select 1 from blocks b
    where (b.blocker_id = ?1 and b.blocked_id = a.owner_id)
       or (b.blocker_id = a.owner_id and b.blocked_id = ?1)
  )
`;

export async function getHome({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  const [prayerRequests, remaining, miracles, memory] = await Promise.all([
    openPrayers(env, viewer, PRAYER_BATCH),
    openPrayerCount(env, viewer),
    recentMiracles(env, viewer),
    onThisDay(env, viewer),
  ]);

  const prayed = await prayedPostIds(
    env,
    viewer,
    [...prayerRequests, ...miracles, ...(memory ? [memory] : [])].map((post) => post.id),
  );

  const view = (post: (typeof prayerRequests)[number]) =>
    serializePost(post, { viewerAccountId: viewer.accountId, hasPrayed: prayed.has(post.id) });

  return json({
    prayerRequests: prayerRequests.map(view),
    // What is left after this batch, so the client can offer "see more" as a deliberate
    // choice instead of loading the next page automatically.
    remainingPrayerRequests: Math.max(remaining - prayerRequests.length, 0),
    recentMiracles: miracles.map(view),
    memory: memory ? view(memory) : null,
  });
}

/**
 * People who could use prayer.
 *
 * Ordered by **fewest responses first**, not by recency or popularity. A prayer nobody has
 * carried yet is the one that most needs carrying, and ranking by engagement would quietly
 * turn this into a popularity contest — which is the thing the product is explicitly not
 * (rule 13, docs/product-spec.md).
 *
 * Excludes the viewer's own prayers and anything they have already prayed for, so the set
 * is genuinely finishable.
 */
async function openPrayers(env: Env, viewer: Viewer, limit: number) {
  const { results } = await env.DB.prepare(`
    select ${COLUMNS} ${FROM}
    where p.type = 'prayer'
      and p.status = 'active'
      and p.visibility = 'public'
      and a.owner_id <> ?1
      and not exists (
        select 1 from prayer_responses pr where pr.post_id = p.id and pr.account_id = ?1
      )
      and ${NOT_BLOCKED}
    order by p.prayer_response_count asc, p.created_at desc, p.id desc
    limit ?2
  `)
    .bind(viewer.accountId, limit)
    .all<PostRow>();

  return results.map(toPostRecord);
}

async function openPrayerCount(env: Env, viewer: Viewer): Promise<number> {
  const row = await env.DB.prepare(`
    select count(*) as total ${FROM}
    where p.type = 'prayer'
      and p.status = 'active'
      and p.visibility = 'public'
      and a.owner_id <> ?1
      and not exists (
        select 1 from prayer_responses pr where pr.post_id = p.id and pr.account_id = ?1
      )
      and ${NOT_BLOCKED}
  `)
    .bind(viewer.accountId)
    .first<{ total: number }>();

  return row?.total ?? 0;
}

/** Miracles around you — other people's, so Home is about the community, not a mirror. */
async function recentMiracles(env: Env, viewer: Viewer) {
  const { results } = await env.DB.prepare(`
    select ${COLUMNS} ${FROM}
    where p.type = 'miracle'
      and p.status = 'active'
      and p.visibility = 'public'
      and a.owner_id <> ?1
      and ${NOT_BLOCKED}
    order by p.created_at desc, p.id desc
    limit ?2
  `)
    .bind(viewer.accountId, RECENT_MIRACLES)
    .all<PostRow>();

  return results.map(toPostRecord);
}

/**
 * On This Day: something the viewer wrote on this date in an earlier year.
 *
 * Only ever their own, and only ever a miracle, gratitude or answered prayer — never an
 * open prayer. Resurfacing "please pray for my marriage" from three years ago, with no
 * indication of how it turned out, would be a small cruelty.
 */
async function onThisDay(env: Env, viewer: Viewer) {
  const now = new Date();
  const monthDay = `${String(now.getUTCMonth() + 1).padStart(2, '0')}-${String(
    now.getUTCDate(),
  ).padStart(2, '0')}`;
  const thisYear = String(now.getUTCFullYear());

  const row = await env.DB.prepare(`
    select ${COLUMNS} ${FROM}
    where a.owner_id = ?1
      and p.status <> 'removed'
      and (p.type in ('miracle', 'gratitude', 'testimony') or p.status = 'answered')
      and strftime('%m-%d', p.created_at / 1000, 'unixepoch') = ?2
      and strftime('%Y', p.created_at / 1000, 'unixepoch') < ?3
    order by p.created_at desc
    limit 1
  `)
    .bind(viewer.accountId, monthDay, thisYear)
    .first<PostRow>();

  return row ? toPostRecord(row) : null;
}
