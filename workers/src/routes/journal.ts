import type { RouteContext } from '../http/router';
import { requireViewer, type Viewer } from '../auth/context';
import { json } from '../http/responses';
import { pageLimit } from '../http/body';
import { formatCursor, parseCursor, prayedPostIds, type Cursor } from '../db/posts';
import { POST_TYPES, serializePost, toPostRecord, type PostRow, type PostType } from '../db/types';
import type { Env } from '../env';

/**
 * The Journal: everything you have ever written, and the tools to find it again.
 *
 * This is the part of the product that still matters if the social side goes quiet, so it
 * is built to be lived in — grouped by year, filterable, searchable, and exportable.
 *
 * **Every query here is scoped to the viewer's own authorship.** There is no account
 * parameter on any of these routes, so there is no shape of request that reads somebody
 * else's history. Search in particular never crosses accounts.
 */

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

interface JournalQuery {
  type: PostType | null;
  search: string | null;
  year: string | null;
  cursor: Cursor | null;
  limit: number;
}

function readQuery(url: URL): JournalQuery {
  const rawType = url.searchParams.get('type');
  const rawSearch = url.searchParams.get('q')?.trim() ?? '';
  const rawYear = url.searchParams.get('year');

  return {
    type: POST_TYPES.includes(rawType as PostType) ? (rawType as PostType) : null,
    // A single character matches almost everything and costs a full scan for nothing.
    search: rawSearch.length >= 2 ? rawSearch.slice(0, 100) : null,
    year: /^\d{4}$/.test(rawYear ?? '') ? rawYear : null,
    cursor: parseCursor(url.searchParams.get('cursor')),
    limit: pageLimit(url),
  };
}

export async function getJournal({ request, env, url }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const query = readQuery(url);

  const conditions = ["a.owner_id = ?1", "p.status <> 'removed'"];
  const bindings: unknown[] = [viewer.accountId];

  if (query.type) {
    bindings.push(query.type);
    conditions.push(`p.type = ?${bindings.length}`);
  }

  if (query.search) {
    // `like` with a leading wildcard cannot use an index, so this is a scan — but it is a
    // scan of one person's own posts, already narrowed by the authorship index. If a
    // journal ever grows large enough for that to hurt, the answer is an FTS5 table kept
    // in step by triggers, not a looser query.
    bindings.push(`%${escapeLike(query.search)}%`);
    conditions.push(`p.body like ?${bindings.length} escape '\\'`);
  }

  if (query.year) {
    bindings.push(query.year);
    conditions.push(`strftime('%Y', p.created_at / 1000, 'unixepoch') = ?${bindings.length}`);
  }

  if (query.cursor) {
    bindings.push(query.cursor.createdAt, query.cursor.id);
    conditions.push(`(a.created_at, a.post_id) < (?${bindings.length - 1}, ?${bindings.length})`);
  }

  bindings.push(query.limit);

  const { results } = await env.DB.prepare(`
    select ${COLUMNS} ${FROM}
    where ${conditions.join(' and ')}
    order by a.created_at desc, a.post_id desc
    limit ?${bindings.length}
  `)
    .bind(...bindings)
    .all<PostRow>();

  const posts = results.map(toPostRecord);
  const prayed = await prayedPostIds(env, viewer, posts.map((post) => post.id));

  return json({
    items: posts.map((post) =>
      serializePost(post, {
        viewerAccountId: viewer.accountId,
        hasPrayed: prayed.has(post.id),
      }),
    ),
    nextCursor: posts.length === query.limit && posts.length > 0
      ? formatCursor(posts[posts.length - 1]!)
      : null,
  });
}

/**
 * The shape of a life, in counts.
 *
 * Gives the timeline its skeleton — which years exist, how much is in each — so someone can
 * jump to 2027 without paging through everything since.
 *
 * These are counts of one's own entries. They are memory, not a score: nothing here is
 * shown to anyone else, and there is no comparison to make (docs/product-spec.md).
 */
export async function getJournalSummary({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  const { results } = await env.DB.prepare(`
    select strftime('%Y', p.created_at / 1000, 'unixepoch') as year,
           p.type as type,
           count(*) as count
    ${FROM}
    where a.owner_id = ?1 and p.status <> 'removed'
    group by year, type
    order by year desc
  `)
    .bind(viewer.accountId)
    .all<{ year: string; type: PostType; count: number }>();

  const byYear = new Map<string, { year: number; total: number; byType: Record<string, number> }>();
  for (const row of results) {
    const entry = byYear.get(row.year) ?? { year: Number(row.year), total: 0, byType: {} };
    entry.total += row.count;
    entry.byType[row.type] = (entry.byType[row.type] ?? 0) + row.count;
    byYear.set(row.year, entry);
  }

  const years = [...byYear.values()].sort((a, b) => b.year - a.year);

  return json({
    years,
    total: years.reduce((sum, year) => sum + year.total, 0),
  });
}

/**
 * Everything you have written, in one document.
 *
 * The product's claim is that people stay because their history is here, **not** because it
 * is difficult to leave. Export makes that literal: a person can take the whole thing and
 * go, and the fact that they can is why staying means something.
 *
 * Includes private entries and posts published anonymously — they are theirs either way —
 * along with prayer updates and the prayer/miracle links, so the stories survive the trip.
 */
export async function exportJournal({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  const [posts, updates, links, profile] = await Promise.all([
    ownPosts(env, viewer),
    ownUpdates(env, viewer),
    ownLinks(env, viewer),
    env.DB.prepare('select username, display_name, created_at from profiles where account_id = ?')
      .bind(viewer.accountId)
      .first<{ username: string; display_name: string; created_at: number }>(),
  ]);

  const updatesByPost = new Map<string, { body: string; createdAt: number }[]>();
  for (const update of updates) {
    const list = updatesByPost.get(update.post_id) ?? [];
    list.push({ body: update.body, createdAt: update.created_at });
    updatesByPost.set(update.post_id, list);
  }

  const answeredBy = new Map(links.map((link) => [link.prayer_post_id, link.miracle_post_id]));
  const cameFrom = new Map(links.map((link) => [link.miracle_post_id, link.prayer_post_id]));

  return new Response(
    JSON.stringify(
      {
        exportedAt: Date.now(),
        format: 'my-miracles/journal-export@1',
        profile: profile
          ? {
              username: profile.username,
              displayName: profile.display_name,
              joinedAt: profile.created_at,
            }
          : null,
        entries: posts.map((row) => ({
          id: row.id,
          type: row.type,
          body: row.body,
          visibility: row.visibility,
          status: row.status,
          anonymous: row.display_profile_id === null,
          createdAt: row.created_at,
          answeredAt: row.answered_at,
          prayerResponseCount: row.prayer_response_count,
          updates: updatesByPost.get(row.id) ?? [],
          answeredByMiracleId: answeredBy.get(row.id) ?? null,
          cameFromPrayerId: cameFrom.get(row.id) ?? null,
        })),
      },
      null,
      2,
    ),
    {
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-disposition': 'attachment; filename="my-miracles-journal.json"',
      },
    },
  );
}

interface ExportRow {
  id: string;
  type: string;
  body: string;
  visibility: string;
  status: string;
  display_profile_id: string | null;
  created_at: number;
  answered_at: number | null;
  prayer_response_count: number;
}

async function ownPosts(env: Env, viewer: Viewer): Promise<ExportRow[]> {
  const { results } = await env.DB.prepare(`
    select p.id, p.type, p.body, p.visibility, p.status, p.display_profile_id,
           p.created_at, p.answered_at, p.prayer_response_count
    from posts p
    join post_authorship a on a.post_id = p.id
    where a.owner_id = ? and p.status <> 'removed'
    order by p.created_at asc
  `)
    .bind(viewer.accountId)
    .all<ExportRow>();
  return results;
}

async function ownUpdates(env: Env, viewer: Viewer) {
  const { results } = await env.DB.prepare(`
    select u.post_id, u.body, u.created_at
    from post_updates u
    join post_authorship a on a.post_id = u.post_id
    where a.owner_id = ?
    order by u.created_at asc
  `)
    .bind(viewer.accountId)
    .all<{ post_id: string; body: string; created_at: number }>();
  return results;
}

async function ownLinks(env: Env, viewer: Viewer) {
  const { results } = await env.DB.prepare(`
    select l.prayer_post_id, l.miracle_post_id
    from answered_links l
    join post_authorship a on a.post_id = l.prayer_post_id
    where a.owner_id = ?
  `)
    .bind(viewer.accountId)
    .all<{ prayer_post_id: string; miracle_post_id: string }>();
  return results;
}

/** Stops a `%` or `_` in someone's search text from behaving as a wildcard. */
function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}
