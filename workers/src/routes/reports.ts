import type { RouteContext } from '../http/router';
import { requireViewer, type Viewer } from '../auth/context';
import { conflict, hidden, json } from '../http/responses';
import { optionalString, readJson, requireEnum } from '../http/body';
import { loadViewablePost } from '../authz/policy';
import { now, uuidv7 } from '../db/ids';

const CATEGORIES = [
  'harassment',
  'sexual',
  'graphic',
  'spam',
  'scam',
  'self_harm',
  'impersonation',
  'medical_misinformation',
  'privacy',
  'other',
] as const;

const SUBJECT_TYPES = ['post', 'comment', 'profile'] as const;

/**
 * Categories that get a human being sooner. Reports are a signal, never a verdict — a
 * high-risk category raises priority in the queue and nothing else. Brigading must not be
 * able to manufacture guilt (docs/product-spec.md).
 */
const HIGH_RISK: ReadonlySet<string> = new Set(['self_harm', 'sexual', 'graphic', 'scam']);

export async function createReport({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const body = await readJson(request);

  const subjectType = requireEnum(body, 'subjectType', SUBJECT_TYPES);
  const subjectId = String(body.subjectId ?? '');
  const category = requireEnum(body, 'category', CATEGORIES);
  const details = optionalString(body, 'details', { max: 1000 });

  // You may only report something you can already see. Otherwise this endpoint becomes an
  // oracle: submit ids until one is accepted and you have discovered which private posts
  // exist.
  await assertSubjectVisible(env, viewer, subjectType, subjectId);

  const timestamp = now();
  const risk = HIGH_RISK.has(category) ? 'high' : 'low';

  // Ten reports about one post converge on one case rather than filling the queue with
  // ten entries about the same thing.
  const existingCase = await env.DB.prepare(
    `select id from moderation_cases
     where subject_type = ? and subject_id = ? and state in ('open', 'triage')`,
  )
    .bind(subjectType, subjectId)
    .first<{ id: string }>();

  const caseId = existingCase?.id ?? uuidv7();

  const statements = existingCase
    ? [
        env.DB.prepare(
          `update moderation_cases
           set report_count = report_count + 1,
               risk = case when ? = 'high' then 'high' else risk end,
               updated_at = ?
           where id = ?`,
        ).bind(risk, timestamp, caseId),
      ]
    : [
        env.DB.prepare(
          `insert into moderation_cases
             (id, subject_type, subject_id, risk, state, report_count, created_at, updated_at)
           values (?, ?, ?, ?, 'open', 1, ?, ?)`,
        ).bind(caseId, subjectType, subjectId, risk, timestamp, timestamp),
      ];

  try {
    await env.DB.batch([
      ...statements,
      env.DB.prepare(
        `insert into reports (id, reporter_id, subject_type, subject_id, category, details, case_id, created_at)
         values (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        uuidv7(),
        viewer.accountId,
        subjectType,
        subjectId,
        category,
        details ?? null,
        caseId,
        timestamp,
      ),
    ]);
  } catch (error) {
    // One report per person per subject, enforced by a unique index.
    if (String(error).includes('UNIQUE')) {
      throw conflict('you have already reported this');
    }
    throw error;
  }

  // The response deliberately says nothing about the case: not its id, not how many other
  // people reported, not what happens next. That is operational information, and telling a
  // reporter their report was the tenth would let anyone probe moderation state.
  return json({ submitted: true }, 201);
}

async function assertSubjectVisible(
  env: RouteContext['env'],
  viewer: Viewer,
  subjectType: (typeof SUBJECT_TYPES)[number],
  subjectId: string,
): Promise<void> {
  switch (subjectType) {
    case 'post':
      await loadViewablePost(env, viewer, subjectId);
      return;
    case 'comment': {
      const comment = await env.DB.prepare('select post_id from comments where id = ?')
        .bind(subjectId)
        .first<{ post_id: string }>();
      if (!comment) throw hidden();
      await loadViewablePost(env, viewer, comment.post_id);
      return;
    }
    case 'profile': {
      const profile = await env.DB.prepare('select account_id from profiles where account_id = ?')
        .bind(subjectId)
        .first<{ account_id: string }>();
      if (!profile) throw hidden();
      return;
    }
  }
}
