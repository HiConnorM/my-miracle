import type { RouteContext } from '../http/router';
import { requireStaff, type Moderator } from '../authz/staff';
import { conflict, invalid, json } from '../http/responses';
import { pageLimit, optionalString, readJson, requireEnum, requireString } from '../http/body';
import { now, uuidv7 } from '../db/ids';
import type { Env } from '../env';

/**
 * The moderation surface.
 *
 * Two rules govern everything here, and both come from `docs/product-spec.md`:
 *
 *   1. **Every decision writes an audit record.** Actor, previous state, new state, reason
 *      code, timestamp. No exceptions, including "keep" — deciding something is fine is a
 *      decision, and the absence of a record is indistinguishable from nobody looking.
 *
 *   2. **Nobody edits content by hand.** There is no route that deletes a row. Removal sets
 *      a status and records why, so an action can be explained and reversed. A dashboard
 *      that runs `delete from posts` leaves no way to answer "who did this, and why?".
 *
 * Reports are a signal, never a verdict. Volume raises priority in the queue and nothing
 * else — brigading must not be able to manufacture guilt.
 */

const ACTIONS = [
  'keep',
  'warn',
  'remove',
  'restrict',
  'suspend',
  'reinstate',
  'escalate',
  'assign',
] as const;

type Action = (typeof ACTIONS)[number];

/** Actions that resolve a case. The rest leave it open for someone to come back to. */
const RESOLVING: ReadonlySet<Action> = new Set(['keep', 'remove', 'suspend', 'restrict', 'reinstate']);

// MARK: - The queue

/**
 * The queue, most serious first.
 *
 * Ordered by risk then age, so a self-harm report never waits behind a week of spam, and
 * nothing sits forgotten at the bottom.
 */
export async function listCases({ request, env, url }: RouteContext): Promise<Response> {
  await requireStaff(request, env);

  const state = url.searchParams.get('state') ?? 'open';
  const states = state === 'all'
    ? ['open', 'triage', 'actioned', 'dismissed']
    : [state];

  const placeholders = states.map(() => '?').join(', ');
  const { results } = await env.DB.prepare(`
    select c.id, c.subject_type, c.subject_id, c.risk, c.state, c.report_count,
           c.created_at, c.updated_at, c.assigned_to
    from moderation_cases c
    where c.state in (${placeholders})
    order by
      case c.risk when 'critical' then 0 when 'high' then 1 when 'medium' then 2 else 3 end,
      c.created_at asc
    limit ?
  `)
    .bind(...states, pageLimit(url, 50, 100))
    .all<CaseRow>();

  return json({ items: results.map(serializeCase) });
}

/**
 * One case, with everything needed to decide.
 *
 * Includes the content itself, who reported it and why, and the author's prior moderation
 * history — because "has this happened before?" is the difference between a warning and a
 * suspension.
 *
 * A moderator sees the real author even of an anonymous post. That is the point of rule 8:
 * anonymous to other users, never to the platform.
 */
export async function getCase({ request, env, params }: RouteContext): Promise<Response> {
  await requireStaff(request, env);

  const record = await env.DB.prepare(`
    select id, subject_type, subject_id, risk, state, report_count,
           created_at, updated_at, assigned_to
    from moderation_cases where id = ?
  `)
    .bind(params.id!)
    .first<CaseRow>();

  if (!record) throw conflict('no such case');

  const [subject, reports, actions] = await Promise.all([
    loadSubject(env, record.subject_type, record.subject_id),
    env.DB.prepare(`
      select r.id, r.category, r.details, r.created_at, pr.username as reporter
      from reports r
      left join profiles pr on pr.account_id = r.reporter_id
      where r.case_id = ?
      order by r.created_at asc
    `)
      .bind(record.id)
      .all<{ id: string; category: string; details: string | null; created_at: number; reporter: string | null }>(),
    env.DB.prepare(`
      select a.id, a.action, a.reason_code, a.notes, a.created_at, pr.username as actor
      from moderation_actions a
      left join profiles pr on pr.account_id = a.actor_id
      where a.case_id = ?
      order by a.created_at asc
    `)
      .bind(record.id)
      .all<{ id: string; action: string; reason_code: string; notes: string | null; created_at: number; actor: string | null }>(),
  ]);

  const history = subject?.authorAccountId
    ? await authorHistory(env, subject.authorAccountId, record.id)
    : [];

  return json({
    ...serializeCase(record),
    subject,
    reports: reports.results.map((row) => ({
      id: row.id,
      category: row.category,
      details: row.details,
      reporter: row.reporter,
      createdAt: row.created_at,
    })),
    actions: actions.results.map((row) => ({
      id: row.id,
      action: row.action,
      reasonCode: row.reason_code,
      notes: row.notes,
      actor: row.actor,
      createdAt: row.created_at,
    })),
    authorHistory: history,
  });
}

/**
 * Records a decision, and applies its effect.
 *
 * The audit row and the effect are one batch. A suspension that lands without a record of
 * who ordered it, or a record with no effect, would both be worse than nothing.
 */
export async function actOnCase({ request, env, params }: RouteContext): Promise<Response> {
  const moderator = await requireStaff(request, env);
  const body = await readJson(request);

  const action = requireEnum<Action>(body, 'action', ACTIONS);
  // Free-text notes are optional; a reason code is not. "Because I said so" is not an
  // audit trail.
  const reasonCode = requireString(body, 'reasonCode', { min: 2, max: 60 });
  const notes = optionalString(body, 'notes', { max: 1000 });

  const record = await env.DB.prepare(
    'select id, subject_type, subject_id, state from moderation_cases where id = ?',
  )
    .bind(params.id!)
    .first<{ id: string; subject_type: string; subject_id: string; state: string }>();

  if (!record) throw conflict('no such case');

  const timestamp = now();
  const nextState = RESOLVING.has(action)
    ? (action === 'keep' ? 'dismissed' : 'actioned')
    : action === 'escalate' ? 'triage' : record.state;

  const statements = [
    // The audit row comes first and is never conditional.
    env.DB.prepare(`
      insert into moderation_actions
        (id, case_id, actor_id, action, reason_code, previous_state, new_state, notes, created_at)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      uuidv7(),
      record.id,
      moderator.accountId,
      action,
      reasonCode,
      record.state,
      nextState,
      notes ?? null,
      timestamp,
    ),

    env.DB.prepare(`
      update moderation_cases
      set state = ?, updated_at = ?, resolved_at = ?, assigned_to = coalesce(assigned_to, ?)
      where id = ?
    `).bind(
      nextState,
      timestamp,
      RESOLVING.has(action) ? timestamp : null,
      moderator.accountId,
      record.id,
    ),

    ...effectOf(env, action, record.subject_type, record.subject_id, reasonCode, timestamp),
  ];

  await env.DB.batch(statements);

  return json({ action, state: nextState });
}

/**
 * What an action actually does.
 *
 * Note what is absent: nothing here deletes a row. Removal is a status change with a
 * reason, so it can be explained to the person it happened to and undone if it was wrong.
 */
function effectOf(
  env: Env,
  action: Action,
  subjectType: string,
  subjectId: string,
  reasonCode: string,
  timestamp: number,
): D1PreparedStatement[] {
  switch (action) {
    case 'remove':
      if (subjectType === 'post') {
        return [
          env.DB.prepare(
            `update posts set status = 'removed', removed_reason = ?, updated_at = ? where id = ?`,
          ).bind(reasonCode, timestamp, subjectId),
        ];
      }
      if (subjectType === 'comment') {
        return [
          env.DB.prepare(
            `update comments set status = 'removed', updated_at = ? where id = ?`,
          ).bind(timestamp, subjectId),
        ];
      }
      return [];

    case 'suspend':
      // Suspending also revokes every session, so it takes effect now rather than whenever
      // the current access token happens to expire.
      return [
        env.DB.prepare(
          `update accounts set status = 'suspended', suspended_at = ?, suspension_reason = ?, updated_at = ?
           where id = ?`,
        ).bind(timestamp, reasonCode, timestamp, subjectId),
        env.DB.prepare(
          'update refresh_tokens set revoked_at = ? where account_id = ? and revoked_at is null',
        ).bind(timestamp, subjectId),
      ];

    case 'reinstate':
      return subjectType === 'profile'
        ? [
            env.DB.prepare(
              `update accounts set status = 'active', suspended_at = null, suspension_reason = null,
                                   updated_at = ?
               where id = ?`,
            ).bind(timestamp, subjectId),
          ]
        : [
            env.DB.prepare(
              `update posts set status = 'active', removed_reason = null, updated_at = ? where id = ?`,
            ).bind(timestamp, subjectId),
          ];

    // `keep`, `warn`, `restrict`, `escalate` and `assign` change no content. They are still
    // recorded — deciding something is fine is a decision, and a case with no action looks
    // exactly like a case nobody opened.
    default:
      return [];
  }
}

// MARK: - Reading the subject

interface CaseRow {
  id: string;
  subject_type: string;
  subject_id: string;
  risk: string;
  state: string;
  report_count: number;
  created_at: number;
  updated_at: number;
  assigned_to: string | null;
}

function serializeCase(row: CaseRow) {
  return {
    id: row.id,
    subjectType: row.subject_type,
    subjectId: row.subject_id,
    risk: row.risk,
    state: row.state,
    reportCount: row.report_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

interface Subject {
  kind: string;
  body: string | null;
  status: string | null;
  visibility: string | null;
  createdAt: number | null;
  /** The real author, even for an anonymous post. Rule 8: never anonymous to the platform. */
  author: string | null;
  authorAccountId: string | null;
  isAnonymous: boolean;
}

async function loadSubject(
  env: Env,
  subjectType: string,
  subjectId: string,
): Promise<Subject | null> {
  if (subjectType === 'post') {
    const row = await env.DB.prepare(`
      select p.body, p.status, p.visibility, p.created_at, p.display_profile_id,
             a.owner_id, pr.username as author
      from posts p
      join post_authorship a on a.post_id = p.id
      left join profiles pr on pr.account_id = a.owner_id
      where p.id = ?
    `)
      .bind(subjectId)
      .first<{
        body: string; status: string; visibility: string; created_at: number;
        display_profile_id: string | null; owner_id: string; author: string | null;
      }>();
    if (!row) return null;

    return {
      kind: 'post',
      body: row.body,
      status: row.status,
      visibility: row.visibility,
      createdAt: row.created_at,
      author: row.author,
      authorAccountId: row.owner_id,
      isAnonymous: row.display_profile_id === null,
    };
  }

  if (subjectType === 'comment') {
    const row = await env.DB.prepare(`
      select c.body, c.status, c.created_at, c.author_account_id, pr.username as author
      from comments c
      left join profiles pr on pr.account_id = c.author_account_id
      where c.id = ?
    `)
      .bind(subjectId)
      .first<{ body: string; status: string; created_at: number; author_account_id: string; author: string | null }>();
    if (!row) return null;

    return {
      kind: 'comment',
      body: row.body,
      status: row.status,
      visibility: null,
      createdAt: row.created_at,
      author: row.author,
      authorAccountId: row.author_account_id,
      isAnonymous: false,
    };
  }

  const row = await env.DB.prepare(`
    select pr.username, pr.display_name, pr.bio, pr.created_at, ac.status
    from profiles pr
    join accounts ac on ac.id = pr.account_id
    where pr.account_id = ?
  `)
    .bind(subjectId)
    .first<{ username: string; display_name: string; bio: string | null; created_at: number; status: string }>();
  if (!row) return null;

  return {
    kind: 'profile',
    body: row.bio,
    status: row.status,
    visibility: null,
    createdAt: row.created_at,
    author: row.username,
    authorAccountId: subjectId,
    isAnonymous: false,
  };
}

/**
 * What has been decided about this person before.
 *
 * A first offence and a fifth deserve different answers, and a moderator cannot know which
 * this is without being shown.
 */
async function authorHistory(env: Env, accountId: string, excludingCase: string) {
  const { results } = await env.DB.prepare(`
    select a.action, a.reason_code, a.created_at, c.subject_type
    from moderation_actions a
    join moderation_cases c on c.id = a.case_id
    where c.subject_id = ?1
       or c.subject_id in (
            select post_id from post_authorship where owner_id = ?1
          )
       or c.subject_id in (
            select id from comments where author_account_id = ?1
          )
    and a.case_id <> ?2
    order by a.created_at desc
    limit 20
  `)
    .bind(accountId, excludingCase)
    .all<{ action: string; reason_code: string; created_at: number; subject_type: string }>();

  return results.map((row) => ({
    action: row.action,
    reasonCode: row.reason_code,
    subjectType: row.subject_type,
    createdAt: row.created_at,
  }));
}

export { invalid };
