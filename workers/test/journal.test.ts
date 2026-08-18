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
 * The Journal is the durable half of the product — the part that still matters if the
 * social side goes quiet.
 *
 * The sharpest tests here are the ones that prove it is **yours**: search never crosses
 * accounts, the summary counts only your own entries, and export hands back everything so
 * nobody is staying because leaving is hard.
 */

let connor: TestAccount;
let gabi: TestAccount;

beforeEach(async () => {
  await resetDatabase();
  connor = await createAccount('connor');
  gabi = await createAccount('gabi');
});

interface Page {
  items: { id: string; type: string; body: string }[];
  nextCursor: string | null;
}

async function journal(account: TestAccount, query = ''): Promise<Page> {
  return (await api(account, `/v1/me/journal${query}`)).json() as Promise<Page>;
}

async function createPostAt(owner: TestAccount, when: Date, options: Record<string, unknown> = {}) {
  const id = await createPost(owner, options as never);
  await env.DB.batch([
    env.DB.prepare('update posts set created_at = ? where id = ?').bind(when.getTime(), id),
    env.DB.prepare('update post_authorship set created_at = ? where post_id = ?')
      .bind(when.getTime(), id),
  ]);
  return id;
}

describe('the timeline', () => {
  it('holds private, public and anonymous entries alike', async () => {
    await createPost(connor, { type: 'gratitude', visibility: 'private' });
    await createPost(connor, { type: 'miracle', visibility: 'public' });
    await createPost(connor, { type: 'prayer', visibility: 'public', anonymous: true });
    await createPost(gabi, { type: 'miracle', visibility: 'public' });

    const page = await journal(connor);
    expect(page.items).toHaveLength(3);
  });

  it('reads newest first', async () => {
    const older = await createPostAt(connor, new Date('2026-01-05T12:00:00Z'), { type: 'miracle' });
    const newer = await createPostAt(connor, new Date('2026-08-05T12:00:00Z'), { type: 'miracle' });

    const page = await journal(connor);
    expect(page.items.map((item) => item.id)).toEqual([newer, older]);
  });

  it('pages without repeating or skipping', async () => {
    const created: string[] = [];
    for (let i = 0; i < 7; i++) {
      created.push(await createPostAt(connor, new Date(2026, 0, i + 1, 12), { type: 'miracle', body: `Entry ${i}` }));
    }

    const first = await journal(connor, '?limit=3');
    expect(first.items).toHaveLength(3);
    expect(first.nextCursor).not.toBeNull();

    const second = await journal(connor, `?limit=3&cursor=${encodeURIComponent(first.nextCursor!)}`);
    const seen = [...first.items, ...second.items].map((item) => item.id);

    expect(new Set(seen).size).toBe(6);
    expect(seen.every((id) => created.includes(id))).toBe(true);
  });

  it('stops offering a cursor at the end', async () => {
    await createPost(connor, { type: 'miracle' });
    const page = await journal(connor, '?limit=25');
    expect(page.nextCursor).toBeNull();
  });
});

describe('filters', () => {
  beforeEach(async () => {
    await createPost(connor, { type: 'miracle', body: 'A miracle' });
    await createPost(connor, { type: 'prayer', body: 'A prayer', visibility: 'public' });
    await createPost(connor, { type: 'gratitude', body: 'Grateful', visibility: 'private' });
  });

  it.each(['miracle', 'prayer', 'gratitude'])('narrows to %s', async (type) => {
    const page = await journal(connor, `?type=${type}`);
    expect(page.items).toHaveLength(1);
    expect(page.items[0]!.type).toBe(type);
  });

  it('ignores a filter it does not recognise rather than returning nothing', async () => {
    const page = await journal(connor, '?type=nonsense');
    expect(page.items).toHaveLength(3);
  });

  it('narrows to a year', async () => {
    await createPostAt(connor, new Date('2024-06-01T12:00:00Z'), { type: 'miracle', body: 'Older' });

    const page = await journal(connor, '?year=2024');
    expect(page.items).toHaveLength(1);
    expect(page.items[0]!.body).toBe('Older');
  });
});

describe('search', () => {
  beforeEach(async () => {
    await createPost(connor, { type: 'miracle', body: 'We finally got the house.' });
    await createPost(connor, { type: 'miracle', body: 'Dad called for no reason at all.' });
    await createPost(connor, { type: 'gratitude', body: 'A quiet morning.', visibility: 'private' });
  });

  it('finds an entry by its words', async () => {
    const page = await journal(connor, '?q=house');
    expect(page.items).toHaveLength(1);
    expect(page.items[0]!.body).toContain('house');
  });

  it('searches private entries too — they are yours', async () => {
    const page = await journal(connor, '?q=quiet');
    expect(page.items).toHaveLength(1);
  });

  it('is case-insensitive', async () => {
    expect((await journal(connor, '?q=HOUSE')).items).toHaveLength(1);
  });

  it('combines with a filter', async () => {
    const page = await journal(connor, '?q=a&type=gratitude');
    expect(page.items).toHaveLength(1);
    expect(page.items[0]!.type).toBe('gratitude');
  });

  /**
   * The important one. A journal contains illness, marriage, money and grief; search must
   * never reach across accounts, whatever is typed.
   */
  it('never reaches into somebody else’s journal', async () => {
    await createPost(gabi, { type: 'miracle', body: 'We finally got the house.' });

    const page = await journal(connor, '?q=house');
    expect(page.items).toHaveLength(1);

    const raw = await (await api(connor, '/v1/me/journal?q=house')).text();
    expect(raw).not.toContain(gabi.id);
  });

  /** A wildcard typed into the search box is text, not a query. */
  it('treats SQL wildcards as literal characters', async () => {
    await createPost(connor, { type: 'miracle', body: '100% sure it was him.' });

    // "100%" matches the one entry containing it, literally.
    expect((await journal(connor, '?q=100%25')).items).toHaveLength(1);

    // Unescaped, "%s" would match any body containing an "s" — nearly all of them.
    expect((await journal(connor, '?q=%25s')).items).toHaveLength(0);

    // Unescaped, "__" would match any body of two or more characters.
    expect((await journal(connor, '?q=__')).items).toHaveLength(0);
  });

  it('ignores a single character rather than scanning for nothing', async () => {
    expect((await journal(connor, '?q=a')).items).toHaveLength(3);
  });

  it('returns nothing gracefully when there is no match', async () => {
    const page = await journal(connor, '?q=zebra');
    expect(page.items).toHaveLength(0);
    expect(page.nextCursor).toBeNull();
  });
});

describe('the summary', () => {
  interface Summary {
    years: { year: number; total: number; byType: Record<string, number> }[];
    total: number;
  }

  it('counts your entries by year and type', async () => {
    await createPostAt(connor, new Date('2026-03-01T12:00:00Z'), { type: 'miracle' });
    await createPostAt(connor, new Date('2026-07-01T12:00:00Z'), { type: 'miracle' });
    await createPostAt(connor, new Date('2025-05-01T12:00:00Z'), { type: 'gratitude' });

    const summary = await (await api(connor, '/v1/me/journal/summary')).json() as Summary;

    expect(summary.total).toBe(3);
    expect(summary.years.map((y) => y.year)).toEqual([2026, 2025]);
    expect(summary.years[0]!.byType.miracle).toBe(2);
    expect(summary.years[1]!.byType.gratitude).toBe(1);
  });

  it('counts nobody else’s', async () => {
    await createPost(gabi, { type: 'miracle' });
    const summary = await (await api(connor, '/v1/me/journal/summary')).json() as Summary;
    expect(summary.total).toBe(0);
  });

  it('is empty and calm for a new account', async () => {
    const summary = await (await api(connor, '/v1/me/journal/summary')).json() as Summary;
    expect(summary).toEqual({ years: [], total: 0 });
  });
});

describe('export', () => {
  interface Export {
    format: string;
    profile: { username: string } | null;
    entries: {
      id: string;
      body: string;
      visibility: string;
      anonymous: boolean;
      updates: { body: string }[];
      answeredByMiracleId: string | null;
      cameFromPrayerId: string | null;
    }[];
  }

  async function exported(account: TestAccount): Promise<Export> {
    return (await api(account, '/v1/me/export')).json() as Promise<Export>;
  }

  /**
   * The product's claim is that people stay because their history is here, not because
   * leaving is hard. Export makes that literal.
   */
  it('hands back everything, including private and anonymous entries', async () => {
    await createPost(connor, { type: 'gratitude', body: 'Only for me.', visibility: 'private' });
    await createPost(connor, { type: 'prayer', body: 'Asked quietly.', visibility: 'public', anonymous: true });
    await createPost(connor, { type: 'miracle', body: 'Shared with everyone.', visibility: 'public' });

    const result = await exported(connor);

    expect(result.format).toBe('my-miracles/journal-export@1');
    expect(result.entries).toHaveLength(3);
    expect(result.entries.map((e) => e.body).sort()).toEqual(
      ['Asked quietly.', 'Only for me.', 'Shared with everyone.'],
    );
    expect(result.entries.find((e) => e.anonymous)?.body).toBe('Asked quietly.');
  });

  it('keeps the stories intact — updates and the prayer that became a miracle', async () => {
    const prayer = await createPost(connor, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${prayer}/updates`, { body: 'Still waiting.' });
    const answer = await post(connor, `/v1/posts/${prayer}/answer`, { body: 'It happened.' });
    const miracleId = (await answer.json() as { id: string }).id;

    const result = await exported(connor);
    const exportedPrayer = result.entries.find((e) => e.id === prayer)!;
    const exportedMiracle = result.entries.find((e) => e.id === miracleId)!;

    expect(exportedPrayer.updates.map((u) => u.body)).toEqual(['Still waiting.']);
    expect(exportedPrayer.answeredByMiracleId).toBe(miracleId);
    expect(exportedMiracle.cameFromPrayerId).toBe(prayer);
  });

  it('contains nobody else’s writing', async () => {
    await createPost(gabi, { type: 'miracle', body: 'Not yours to take.' });
    await createPost(connor, { type: 'miracle', body: 'Mine.' });

    const raw = await (await api(connor, '/v1/me/export')).text();
    expect(raw).toContain('Mine.');
    expect(raw).not.toContain('Not yours to take.');
    expect(raw).not.toContain(gabi.id);
  });

  it('downloads as a file', async () => {
    const response = await api(connor, '/v1/me/export');
    expect(response.headers.get('content-disposition')).toContain('my-miracles-journal.json');
  });

  it('requires authentication', async () => {
    expect((await api(null, '/v1/me/export')).status).toBe(401);
  });
});
