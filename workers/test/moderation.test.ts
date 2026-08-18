import { describe, it, expect, beforeEach } from 'vitest';
import { env } from 'cloudflare:test';
import {
  api,
  createAccount,
  createPost,
  post,
  resetDatabase,
  type TestAccount,
} from './helpers';

/**
 * Moderation.
 *
 * Two properties matter more than anything else here, and both are asserted rather than
 * assumed: **no ordinary account can reach any of this**, and **every decision leaves an
 * audit record**. A moderation tool without an audit trail is indistinguishable from
 * somebody with database access.
 *
 * There is also no route that deletes a row. Removal sets a status and records why, so an
 * action can be explained to the person it happened to, and undone if it was wrong.
 */

let connor: TestAccount;
let gabi: TestAccount;
let mod: TestAccount;

async function makeStaff(account: TestAccount, role: 'moderator' | 'admin' = 'moderator') {
  await env.DB.prepare(
    'insert into staff (account_id, role, created_at) values (?, ?, ?)',
  )
    .bind(account.id, role, Date.now())
    .run();
}

beforeEach(async () => {
  await resetDatabase();
  await env.DB.prepare('delete from staff').run();
  connor = await createAccount('connor');
  gabi = await createAccount('gabi');
  mod = await createAccount('moderator_kim');
});

/** Reports something, producing a case, and returns the case id. */
async function reportPost(reporter: TestAccount, postId: string, category = 'harassment') {
  await post(reporter, '/v1/reports', { subjectType: 'post', subjectId: postId, category });
  const row = await env.DB.prepare(
    "select id from moderation_cases where subject_type = 'post' and subject_id = ?",
  )
    .bind(postId)
    .first<{ id: string }>();
  return row!.id;
}

interface CaseDetail {
  id: string;
  risk: string;
  state: string;
  reportCount: number;
  subject: { body: string; author: string; isAnonymous: boolean; status: string } | null;
  reports: { category: string; reporter: string | null }[];
  actions: { action: string; reasonCode: string; actor: string | null }[];
  authorHistory: { action: string }[];
}

describe('who can reach moderation', () => {
  /**
   * The most important test in the file. An ordinary account must not be able to see the
   * queue, a case, or take an action.
   */
  it('is invisible to an ordinary account', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    expect((await api(connor, '/v1/moderation/cases')).status).toBe(404);
    expect((await api(connor, `/v1/moderation/cases/${caseId}`)).status).toBe(404);
    expect(
      (await post(connor, `/v1/moderation/cases/${caseId}/actions`, {
        action: 'remove',
        reasonCode: 'i_said_so',
      })).status,
    ).toBe(404);
  });

  /** 404, not 403 — a 403 confirms the surface exists and the case id is real. */
  it('refuses with not-found rather than forbidden', async () => {
    const response = await api(connor, '/v1/moderation/cases');
    expect(response.status).toBe(404);
    expect(await response.text()).not.toContain('forbidden');
  });

  it('is refused without any session at all', async () => {
    expect((await api(null, '/v1/moderation/cases')).status).toBe(401);
  });

  it('opens for staff', async () => {
    await makeStaff(mod);
    expect((await api(mod, '/v1/moderation/cases')).status).toBe(200);
  });

  /** Staff are ordinary accounts with a grant, so suspension applies to them too. */
  it('closes again when a moderator is suspended', async () => {
    await makeStaff(mod);
    await env.DB.prepare("update accounts set status = 'suspended' where id = ?")
      .bind(mod.id).run();

    expect((await api(mod, '/v1/moderation/cases')).status).toBe(401);
  });

  it('closes when the grant is revoked', async () => {
    await makeStaff(mod);
    expect((await api(mod, '/v1/moderation/cases')).status).toBe(200);

    await env.DB.prepare('delete from staff where account_id = ?').bind(mod.id).run();
    expect((await api(mod, '/v1/moderation/cases')).status).toBe(404);
  });
});

describe('the queue', () => {
  beforeEach(async () => {
    await makeStaff(mod);
  });

  it('lists open cases', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await reportPost(connor, id);

    const queue = await (await api(mod, '/v1/moderation/cases')).json() as { items: unknown[] };
    expect(queue.items).toHaveLength(1);
  });

  /**
   * A self-harm report must never wait behind a week of spam.
   */
  it('puts the most serious first', async () => {
    const spam = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Buy now' });
    const urgent = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'I want to disappear' });

    await reportPost(connor, spam, 'spam');
    await reportPost(connor, urgent, 'self_harm');

    const queue = await (await api(mod, '/v1/moderation/cases')).json() as {
      items: { subjectId: string; risk: string }[];
    };

    expect(queue.items[0]!.subjectId).toBe(urgent);
    expect(queue.items[0]!.risk).toBe('high');
  });

  it('converges many reports about one thing onto one case', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const others = await Promise.all([createAccount('ada'), createAccount('bea')]);

    await reportPost(connor, id);
    for (const account of others) {
      await post(account, '/v1/reports', { subjectType: 'post', subjectId: id, category: 'spam' });
    }

    const queue = await (await api(mod, '/v1/moderation/cases')).json() as {
      items: { reportCount: number }[];
    };
    expect(queue.items).toHaveLength(1);
    expect(queue.items[0]!.reportCount).toBe(3);
  });
});

describe('a case', () => {
  beforeEach(async () => {
    await makeStaff(mod);
  });

  it('shows the content, the reports and who reported', async () => {
    const id = await createPost(gabi, {
      type: 'prayer', visibility: 'public', body: 'Something objectionable',
    });
    const caseId = await reportPost(connor, id, 'harassment');

    const detail = await (await api(mod, `/v1/moderation/cases/${caseId}`)).json() as CaseDetail;

    expect(detail.subject?.body).toBe('Something objectionable');
    expect(detail.subject?.author).toBe('gabi');
    expect(detail.reports[0]).toMatchObject({ category: 'harassment', reporter: 'connor' });
  });

  /**
   * Rule 8, from the other side. Anonymous means anonymous to other users; a moderator must
   * be able to see who wrote something, or the platform cannot be accountable for it.
   */
  it('shows the real author of an anonymous post', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public', anonymous: true });
    const caseId = await reportPost(connor, id);

    const detail = await (await api(mod, `/v1/moderation/cases/${caseId}`)).json() as CaseDetail;

    expect(detail.subject?.isAnonymous).toBe(true);
    expect(detail.subject?.author).toBe('gabi');
  });

  /** A first offence and a fifth deserve different answers. */
  it('shows what has been decided about this person before', async () => {
    const first = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'One' });
    const firstCase = await reportPost(connor, first);
    await post(mod, `/v1/moderation/cases/${firstCase}/actions`, {
      action: 'warn', reasonCode: 'first_warning',
    });

    const second = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Two' });
    const secondCase = await reportPost(connor, second);

    const detail = await (await api(mod, `/v1/moderation/cases/${secondCase}`)).json() as CaseDetail;
    expect(detail.authorHistory.map((entry) => entry.action)).toContain('warn');
  });
});

describe('decisions', () => {
  beforeEach(async () => {
    await makeStaff(mod);
  });

  /**
   * The audit trail. Every decision, including "this is fine", records who decided, what
   * changed and why. A case with no action is indistinguishable from a case nobody opened.
   */
  it.each(['keep', 'warn', 'remove', 'restrict', 'suspend', 'escalate'])(
    'records %s with an actor, a reason and both states',
    async (action) => {
      const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
      const caseId = await reportPost(connor, id);

      const response = await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
        action,
        reasonCode: 'community_guidelines_3',
        notes: 'Reviewed the thread.',
      });
      expect(response.status).toBe(200);

      const row = await env.DB.prepare(
        'select actor_id, action, reason_code, previous_state, new_state, notes from moderation_actions where case_id = ?',
      ).bind(caseId).first<{
        actor_id: string; action: string; reason_code: string;
        previous_state: string; new_state: string; notes: string;
      }>();

      expect(row).toMatchObject({
        actor_id: mod.id,
        action,
        reason_code: 'community_guidelines_3',
        previous_state: 'open',
        notes: 'Reviewed the thread.',
      });
      expect(row?.new_state).toBeTruthy();
    },
  );

  it('refuses a decision with no reason', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    const response = await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'remove',
    });
    expect(response.status).toBe(422);
  });

  it('refuses an action it does not recognise', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    const response = await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'delete_everything', reasonCode: 'x',
    });
    expect(response.status).toBe(422);
  });

  it('closes a case that was kept, and one that was actioned', async () => {
    const kept = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Fine' });
    const removed = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Not fine' });

    const keptCase = await reportPost(connor, kept);
    const removedCase = await reportPost(connor, removed);

    await post(mod, `/v1/moderation/cases/${keptCase}/actions`, { action: 'keep', reasonCode: 'no_violation' });
    await post(mod, `/v1/moderation/cases/${removedCase}/actions`, { action: 'remove', reasonCode: 'harassment' });

    const states = await env.DB.prepare(
      'select id, state from moderation_cases order by state',
    ).all<{ id: string; state: string }>();

    expect(states.results.find((r) => r.id === keptCase)?.state).toBe('dismissed');
    expect(states.results.find((r) => r.id === removedCase)?.state).toBe('actioned');
  });
});

describe('what an action does', () => {
  beforeEach(async () => {
    await makeStaff(mod);
  });

  /**
   * Removal is a status change with a reason, never a delete. The row survives so the
   * decision can be explained and reversed.
   */
  it('removes a post without deleting it', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'remove', reasonCode: 'harassment',
    });

    const row = await env.DB.prepare('select status, removed_reason from posts where id = ?')
      .bind(id).first<{ status: string; removed_reason: string }>();

    expect(row).toMatchObject({ status: 'removed', removed_reason: 'harassment' });
  });

  it('makes removed content invisible to everyone but its author', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'remove', reasonCode: 'harassment',
    });

    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(404);
    // The author can still see what happened to their own writing.
    expect((await api(gabi, `/v1/posts/${id}`)).status).toBe(200);

    const feed = await (await api(connor, '/v1/feed')).json() as { items: unknown[] };
    expect(feed.items).toHaveLength(0);
  });

  it('can be undone', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, { action: 'remove', reasonCode: 'harassment' });
    await post(mod, `/v1/moderation/cases/${caseId}/actions`, { action: 'reinstate', reasonCode: 'appeal_upheld' });

    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(200);

    // Both decisions survive in the record.
    const actions = await env.DB.prepare(
      'select action from moderation_actions where case_id = ? order by created_at',
    ).bind(caseId).all<{ action: string }>();
    expect(actions.results.map((r) => r.action)).toEqual(['remove', 'reinstate']);
  });

  /** A suspension must bite now, not whenever the current access token expires. */
  it('suspends an account and revokes its sessions immediately', async () => {
    await post(connor, '/v1/reports', {
      subjectType: 'profile', subjectId: 'gabi', category: 'harassment',
    });
    const caseId = (await env.DB.prepare(
      "select id from moderation_cases where subject_type = 'profile'",
    ).first<{ id: string }>())!.id;

    await env.DB.prepare(
      'insert into refresh_tokens (id, account_id, token_hash, issued_at, expires_at) values (?, ?, ?, ?, ?)',
    ).bind('rt-1', gabi.id, 'hash-1', Date.now(), Date.now() + 100_000).run();

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'suspend', reasonCode: 'repeated_harassment',
    });

    const account = await env.DB.prepare('select status, suspension_reason from accounts where id = ?')
      .bind(gabi.id).first<{ status: string; suspension_reason: string }>();
    expect(account).toMatchObject({ status: 'suspended', suspension_reason: 'repeated_harassment' });

    const token = await env.DB.prepare('select revoked_at from refresh_tokens where id = ?')
      .bind('rt-1').first<{ revoked_at: number | null }>();
    expect(token?.revoked_at).not.toBeNull();

    // And the account can no longer act at all.
    expect((await api(gabi, '/v1/feed')).status).toBe(401);
  });

  it('leaves content alone for a warning', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, { action: 'warn', reasonCode: 'tone' });

    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(200);
  });

  it('removes a comment without deleting it', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const created = await post(connor, `/v1/posts/${id}/comments`, { body: 'Unkind' });
    const commentId = (await created.json() as { id: string }).id;

    await post(gabi, '/v1/reports', {
      subjectType: 'comment', subjectId: commentId, category: 'harassment',
    });
    const caseId = (await env.DB.prepare(
      "select id from moderation_cases where subject_type = 'comment'",
    ).first<{ id: string }>())!.id;

    await post(mod, `/v1/moderation/cases/${caseId}/actions`, {
      action: 'remove', reasonCode: 'harassment',
    });

    const row = await env.DB.prepare('select status from comments where id = ?')
      .bind(commentId).first<{ status: string }>();
    expect(row?.status).toBe('removed');

    const comments = await (await api(gabi, `/v1/posts/${id}/comments`)).json() as { items: unknown[] };
    expect(comments.items).toHaveLength(0);
  });
});

describe('service tokens', () => {
  const RAW = 'mm_staff_console_production_0001';

  async function issue(account: TestAccount, options: { revoked?: boolean; expired?: boolean } = {}) {
    const { sha256Hex } = await import('../src/auth/tokens');
    await env.DB.prepare(`
      insert into staff_tokens (id, account_id, label, token_hash, created_at, expires_at, revoked_at)
      values (?, ?, 'moderation console', ?, ?, ?, ?)
    `).bind(
      'st-1',
      account.id,
      await sha256Hex(RAW),
      Date.now(),
      options.expired ? Date.now() - 1000 : null,
      options.revoked ? Date.now() : null,
    ).run();
  }

  function withToken(token: string, path: string, init: RequestInit = {}) {
    return api(null, path, {
      ...init,
      headers: { ...(init.headers ?? {}), Authorization: `Bearer ${token}` },
    });
  }

  it('opens the moderation surface for the console', async () => {
    await makeStaff(mod);
    await issue(mod);

    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(200);
  });

  /** Attribution survives: the audit trail names the account, not "the console". */
  it('attributes decisions to the staff account it belongs to', async () => {
    await makeStaff(mod);
    await issue(mod);

    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    await withToken(RAW, `/v1/moderation/cases/${caseId}/actions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'remove', reasonCode: 'harassment' }),
    });

    const row = await env.DB.prepare(
      'select actor_id from moderation_actions where case_id = ?',
    ).bind(caseId).first<{ actor_id: string }>();
    expect(row?.actor_id).toBe(mod.id);
  });

  it('is stored only as a hash', async () => {
    await makeStaff(mod);
    await issue(mod);

    const row = await env.DB.prepare('select token_hash from staff_tokens').first<{ token_hash: string }>();
    expect(row?.token_hash).not.toBe(RAW);
    expect(row?.token_hash).toHaveLength(64);
  });

  it('refuses an unknown, revoked or expired token', async () => {
    await makeStaff(mod);

    expect((await withToken('mm_staff_made_up', '/v1/moderation/cases')).status).toBe(401);

    await issue(mod, { revoked: true });
    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(401);

    await env.DB.prepare('delete from staff_tokens').run();
    await issue(mod, { expired: true });
    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(401);
  });

  /** Losing the staff grant closes the door even with a live token. */
  it('stops working when the grant is revoked', async () => {
    await makeStaff(mod);
    await issue(mod);
    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(200);

    await env.DB.prepare('delete from staff where account_id = ?').bind(mod.id).run();
    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(401);
  });

  /** It is a moderation credential, and nothing else. */
  it('opens no ordinary route', async () => {
    await makeStaff(mod);
    await issue(mod);

    for (const path of ['/v1/feed', '/v1/me', '/v1/me/journal', '/v1/home']) {
      expect((await withToken(RAW, path)).status, path).toBe(401);
    }
  });

  it('is refused for an account that is not staff at all', async () => {
    await issue(connor);
    expect((await withToken(RAW, '/v1/moderation/cases')).status).toBe(401);
  });
});

describe('the shape of the tooling', () => {
  /**
   * There is no route that deletes a row, on purpose. `delete from posts` in a dashboard
   * leaves no way to answer "who did this, and why?" (docs/product-spec.md).
   */
  it('offers no way to delete anything', async () => {
    await makeStaff(mod);
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    const caseId = await reportPost(connor, id);

    for (const path of [
      `/v1/moderation/cases/${caseId}`,
      `/v1/moderation/posts/${id}`,
      '/v1/moderation/accounts',
      '/v1/admin/sql',
    ]) {
      const response = await api(mod, path, { method: 'DELETE' });
      expect(response.status).toBe(404);
    }

    // The post is still there.
    const row = await env.DB.prepare('select count(*) as n from posts where id = ?')
      .bind(id).first<{ n: number }>();
    expect(row?.n).toBe(1);
  });
});
