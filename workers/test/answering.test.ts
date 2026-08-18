import { describe, it, expect, beforeEach } from 'vitest';
import { env } from 'cloudflare:test';
import {
  api,
  block,
  createAccount,
  createPost,
  del,
  post,
  resetDatabase,
  type TestAccount,
} from './helpers';

/**
 * The core loop: a prayer is carried, updated, answered, and becomes a miracle.
 *
 * This is the product. Everything else exists to make this feel right, so it is tested at
 * the level someone actually experiences it — two accounts, real requests, real database.
 *
 * The conversion is one D1 batch (rule 10). A partial failure would be quietly awful: a
 * prayer marked answered with no miracle breaks the story, and notifications sent before
 * the link commits would tell people something was answered and then show them nothing.
 */

let connor: TestAccount;
let gabi: TestAccount;

beforeEach(async () => {
  await resetDatabase();
  connor = await createAccount('connor');
  gabi = await createAccount('gabi');
});

interface PostView {
  id: string;
  type: string;
  status: string;
  body: string;
  visibility: string;
  answeredAt: number | null;
  prayerResponseCount: number;
  updateCount: number;
  displayProfile: { username: string } | null;
  isMine: boolean;
  hasPrayed: boolean;
  link?: { id: string; type: string; excerpt: string } | null;
}

describe('the whole journey', () => {
  /**
   * The single most important test in the repository. If this passes, My Miracles works.
   */
  it('carries a prayer from asking to remembering', async () => {
    // Connor asks for prayer.
    const created = await post(connor, '/v1/posts', {
      type: 'prayer',
      body: 'I have an interview on Thursday. It would change a lot for us.',
      visibility: 'public',
    });
    expect(created.status).toBe(201);
    const prayer = await created.json() as PostView;
    expect(prayer.status).toBe('active');

    // Gabi sees it and prays.
    const seen = await api(gabi, `/v1/posts/${prayer.id}`);
    expect(seen.status).toBe(200);
    expect((await seen.json() as PostView).hasPrayed).toBe(false);

    const prayed = await post(gabi, `/v1/posts/${prayer.id}/prayers`, {});
    expect(await prayed.json()).toMatchObject({ prayerResponseCount: 1, hasPrayed: true });

    // Connor sees the support.
    const withSupport = await api(connor, `/v1/posts/${prayer.id}`);
    expect((await withSupport.json() as PostView).prayerResponseCount).toBe(1);

    // Connor posts an update while it is still open.
    const update = await post(connor, `/v1/posts/${prayer.id}/updates`, {
      body: 'It went well. They said they would call by the end of next week.',
    });
    expect(update.status).toBe(201);

    const updates = await api(gabi, `/v1/posts/${prayer.id}/updates`);
    expect((await updates.json() as { items: unknown[] }).items).toHaveLength(1);

    // Connor marks it answered.
    const answered = await post(connor, `/v1/posts/${prayer.id}/answer`, {
      body: 'I got the call. I start on the first.',
    });
    expect(answered.status).toBe(201);
    const miracle = await answered.json() as PostView;
    expect(miracle.type).toBe('miracle');

    // The prayer now points at the miracle...
    const resolvedPrayer = await api(gabi, `/v1/posts/${prayer.id}`);
    const prayerAfter = await resolvedPrayer.json() as PostView;
    expect(prayerAfter.status).toBe('answered');
    expect(prayerAfter.answeredAt).not.toBeNull();
    expect(prayerAfter.link?.id).toBe(miracle.id);
    expect(prayerAfter.link?.type).toBe('miracle');

    // ...and the miracle back at the prayer.
    const resolvedMiracle = await api(gabi, `/v1/posts/${miracle.id}`);
    expect((await resolvedMiracle.json() as PostView).link?.id).toBe(prayer.id);

    // Both are in Connor's journal.
    const journal = await api(connor, '/v1/me/journal');
    const items = (await journal.json() as { items: PostView[] }).items;
    expect(items.map((item) => item.id).sort()).toEqual([prayer.id, miracle.id].sort());

    // Gabi is owed closure, because she prayed.
    const notification = await env.DB.prepare(
      `select recipient_id, type, state from notification_events
       where type = 'answered' and subject_id = ?`,
    )
      .bind(prayer.id)
      .first<{ recipient_id: string; type: string; state: string }>();

    expect(notification).toMatchObject({ recipient_id: gabi.id, state: 'pending' });
  });
});

describe('answering', () => {
  async function openPrayer(owner: TestAccount = connor, options = {}): Promise<string> {
    return createPost(owner, { type: 'prayer', visibility: 'public', ...options });
  }

  it('is refused to anyone but the owner', async () => {
    const id = await openPrayer();
    const response = await post(gabi, `/v1/posts/${id}/answer`, { body: 'not mine to answer' });
    expect(response.status).toBe(403);
  });

  it('is invisible to someone who cannot see the prayer', async () => {
    const id = await openPrayer(connor, { visibility: 'private' });
    const response = await post(gabi, `/v1/posts/${id}/answer`, { body: 'x' });
    expect(response.status).toBe(404);
  });

  it('refuses to answer something that is not a prayer', async () => {
    const id = await createPost(connor, { type: 'miracle', visibility: 'public' });
    const response = await post(connor, `/v1/posts/${id}/answer`, { body: 'x' });
    expect(response.status).toBe(422);
  });

  /** A prayer resolves once. The story has one ending. */
  it('refuses to answer the same prayer twice', async () => {
    const id = await openPrayer();
    expect((await post(connor, `/v1/posts/${id}/answer`, { body: 'first' })).status).toBe(201);

    const second = await post(connor, `/v1/posts/${id}/answer`, { body: 'second' });
    expect(second.status).toBe(409);

    const links = await env.DB.prepare(
      'select count(*) as n from answered_links where prayer_post_id = ?',
    ).bind(id).first<{ n: number }>();
    expect(links?.n).toBe(1);
  });

  it('requires a body', async () => {
    const id = await openPrayer();
    expect((await post(connor, `/v1/posts/${id}/answer`, { body: '' })).status).toBe(422);
  });

  /**
   * Anonymity has to survive the answer. Publishing the miracle under Connor's name would
   * retroactively unmask the prayer he deliberately asked anonymously.
   */
  it('inherits anonymity from the prayer', async () => {
    const id = await openPrayer(connor, { anonymous: true });
    const response = await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened.' });
    const miracle = await response.json() as PostView;

    expect(miracle.displayProfile).toBeNull();

    const body = await (await api(gabi, `/v1/posts/${miracle.id}`)).text();
    expect(body).not.toContain(connor.id);
    expect(body).not.toContain('connor');
  });

  it('inherits visibility from the prayer', async () => {
    const id = await openPrayer(connor, { visibility: 'followers' });
    const response = await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened.' });
    expect((await response.json() as PostView).visibility).toBe('followers');
  });

  it('allows the answer to be more private than the prayer', async () => {
    const id = await openPrayer();
    const response = await post(connor, `/v1/posts/${id}/answer`, {
      body: 'Something I would rather keep.',
      visibility: 'private',
      anonymous: false,
    });
    expect((await response.json() as PostView).visibility).toBe('private');
  });

  it('refuses a private anonymous miracle', async () => {
    const id = await openPrayer();
    const response = await post(connor, `/v1/posts/${id}/answer`, {
      body: 'x',
      visibility: 'private',
      anonymous: true,
    });
    expect(response.status).toBe(422);
  });

  /**
   * If the miracle is private, a stranger looking at the public prayer must not receive its
   * contents through the link — only that the prayer is answered.
   */
  it('hides a private miracle from the public prayer’s link', async () => {
    const id = await openPrayer();
    await post(connor, `/v1/posts/${id}/answer`, {
      body: 'Something I would rather keep.',
      visibility: 'private',
    });

    const strangerView = await api(gabi, `/v1/posts/${id}`);
    const seen = await strangerView.json() as PostView;

    expect(seen.status).toBe('answered');
    expect(seen.link).toBeNull();
    expect(JSON.stringify(seen)).not.toContain('rather keep');
  });

  it('notifies everyone who prayed, and not the author', async () => {
    const id = await openPrayer();
    const third = await createAccount('sam');

    await post(gabi, `/v1/posts/${id}/prayers`, {});
    await post(third, `/v1/posts/${id}/prayers`, {});
    await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened.' });

    const { results } = await env.DB.prepare(
      `select recipient_id from notification_events where type = 'answered' and subject_id = ?`,
    ).bind(id).all<{ recipient_id: string }>();

    expect(results.map((row) => row.recipient_id).sort()).toEqual([gabi.id, third.id].sort());
  });

  it('notifies nobody when nobody prayed', async () => {
    const id = await openPrayer();
    await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened quietly.' });

    const row = await env.DB.prepare(
      `select count(*) as n from notification_events where type = 'answered'`,
    ).first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  /** A retry on a bad connection must not create a second miracle. */
  it('is idempotent under a retry', async () => {
    const id = await openPrayer();
    const key = 'answer-retry-0001';

    const first = await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened.' }, {
      headers: { 'Idempotency-Key': key },
    });
    const second = await post(connor, `/v1/posts/${id}/answer`, { body: 'It happened.' }, {
      headers: { 'Idempotency-Key': key },
    });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect((await second.json() as PostView).id).toBe((await first.json() as PostView).id);

    const miracles = await env.DB.prepare(
      `select count(*) as n from posts where type = 'miracle'`,
    ).first<{ n: number }>();
    expect(miracles?.n).toBe(1);
  });

  /**
   * The invariants are enforced by the database as well as the code, so a bug in this
   * route still cannot produce a prayer with two endings.
   */
  it('cannot be corrupted by writing the link directly', async () => {
    const prayerId = await openPrayer();
    await post(connor, `/v1/posts/${prayerId}/answer`, { body: 'It happened.' });

    // Even bypassing the route entirely, the schema refuses a second ending: the prayer is
    // the primary key of answered_links.
    const anotherMiracle = await createPost(connor, { type: 'miracle', visibility: 'public' });
    await expect(
      env.DB.prepare(
        'insert into answered_links (prayer_post_id, miracle_post_id, created_at) values (?, ?, ?)',
      ).bind(prayerId, anotherMiracle, Date.now()).run(),
    ).rejects.toThrow();
  });
});

describe('prayer updates', () => {
  it('are refused to anyone but the owner', async () => {
    const id = await createPost(connor, { type: 'prayer', visibility: 'public' });
    expect((await post(gabi, `/v1/posts/${id}/updates`, { body: 'x' })).status).toBe(403);
  });

  it('are only for prayers', async () => {
    const id = await createPost(connor, { type: 'miracle', visibility: 'public' });
    expect((await post(connor, `/v1/posts/${id}/updates`, { body: 'x' })).status).toBe(422);
  });

  it('are hidden from someone who cannot see the prayer', async () => {
    const id = await createPost(connor, { type: 'prayer', visibility: 'private' });
    expect((await api(gabi, `/v1/posts/${id}/updates`)).status).toBe(404);
  });

  it('are hidden from a blocked person', async () => {
    const id = await createPost(connor, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/updates`, { body: 'still waiting' });
    await block(connor, gabi);

    expect((await api(gabi, `/v1/posts/${id}/updates`)).status).toBe(404);
  });

  it('keep the count in step', async () => {
    const id = await createPost(connor, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/updates`, { body: 'one' });
    await post(connor, `/v1/posts/${id}/updates`, { body: 'two' });

    const view = await (await api(connor, `/v1/posts/${id}`)).json() as PostView;
    expect(view.updateCount).toBe(2);
  });

  it('are read in the order they were written', async () => {
    const id = await createPost(connor, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/updates`, { body: 'first' });
    await post(connor, `/v1/posts/${id}/updates`, { body: 'second' });

    const items = (await (await api(connor, `/v1/posts/${id}/updates`)).json() as {
      items: { body: string }[];
    }).items;
    expect(items.map((item) => item.body)).toEqual(['first', 'second']);
  });
});

describe('the journal', () => {
  it('holds private, public and anonymous entries alike', async () => {
    await createPost(connor, { type: 'gratitude', visibility: 'private' });
    await createPost(connor, { type: 'miracle', visibility: 'public' });
    await createPost(connor, { type: 'prayer', visibility: 'public', anonymous: true });
    await createPost(gabi, { type: 'miracle', visibility: 'public' });

    const journal = await api(connor, '/v1/me/journal');
    const items = (await journal.json() as { items: PostView[] }).items;

    expect(items).toHaveLength(3);
    expect(items.every((item) => item.isMine)).toBe(true);
  });

  it('is ordered newest first', async () => {
    const older = await createPost(connor, { type: 'miracle', visibility: 'public' });
    await new Promise((resolve) => setTimeout(resolve, 5));
    const newer = await createPost(connor, { type: 'miracle', visibility: 'public' });

    const items = (await (await api(connor, '/v1/me/journal')).json() as {
      items: PostView[];
    }).items;
    expect(items[0]!.id).toBe(newer);
    expect(items[1]!.id).toBe(older);
  });

  it('leaves out content the owner deleted', async () => {
    const id = await createPost(connor, { type: 'miracle', visibility: 'public' });
    await del(connor, `/v1/posts/${id}`);

    const items = (await (await api(connor, '/v1/me/journal')).json() as {
      items: PostView[];
    }).items;
    expect(items).toHaveLength(0);
  });
});
