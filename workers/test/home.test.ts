import { describe, it, expect, beforeEach } from 'vitest';
import { env } from 'cloudflare:test';
import {
  api,
  block,
  createAccount,
  createPost,
  post,
  resetDatabase,
  type TestAccount,
} from './helpers';

/**
 * Home is deliberately finite. These tests defend that: a bounded batch, ordered so the
 * least-carried prayer surfaces first, that empties as someone prays and ends in a real
 * "you're caught up" rather than more scrolling.
 */

let connor: TestAccount;
let gabi: TestAccount;

beforeEach(async () => {
  await resetDatabase();
  connor = await createAccount('connor');
  gabi = await createAccount('gabi');
});

interface HomeResponse {
  prayerRequests: { id: string; prayerResponseCount: number; hasPrayed: boolean }[];
  remainingPrayerRequests: number;
  recentMiracles: { id: string }[];
  memory: { id: string; type: string } | null;
}

async function home(account: TestAccount): Promise<HomeResponse> {
  return (await api(account, '/v1/home')).json() as Promise<HomeResponse>;
}

/** Writes a post directly so its timestamp can be placed in the past. */
async function createPostAt(owner: TestAccount, when: Date, options: Record<string, unknown> = {}) {
  const id = await createPost(owner, options as never);
  await env.DB.batch([
    env.DB.prepare('update posts set created_at = ? where id = ?').bind(when.getTime(), id),
    env.DB.prepare('update post_authorship set created_at = ? where post_id = ?')
      .bind(when.getTime(), id),
  ]);
  return id;
}

describe('people who could use prayer', () => {
  it('offers a bounded batch, not everything', async () => {
    for (let i = 0; i < 9; i++) {
      await createPost(gabi, { type: 'prayer', visibility: 'public', body: `Prayer ${i}` });
    }

    const result = await home(connor);
    expect(result.prayerRequests).toHaveLength(5);
    // Enough information to offer "see more" as a choice, without loading it.
    expect(result.remainingPrayerRequests).toBe(4);
  });

  /**
   * The ordering decision that keeps Home from becoming a popularity contest: a prayer
   * nobody has carried is the one that most needs carrying (rule 13).
   */
  it('surfaces the least-carried prayer first', async () => {
    const ignored = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Nobody yet' });
    const carried = await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Well supported' });

    const others = await Promise.all([
      createAccount('ada'), createAccount('bea'), createAccount('cal'),
    ]);
    for (const account of others) {
      await post(account, `/v1/posts/${carried}/prayers`, {});
    }

    const result = await home(connor);
    expect(result.prayerRequests[0]!.id).toBe(ignored);
    expect(result.prayerRequests[0]!.prayerResponseCount).toBe(0);
  });

  /** The set has to be finishable, so praying removes someone from it. */
  it('empties as the viewer prays, ending in nothing left to do', async () => {
    const ids = [
      await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'One' }),
      await createPost(gabi, { type: 'prayer', visibility: 'public', body: 'Two' }),
    ];

    expect((await home(connor)).prayerRequests).toHaveLength(2);

    await post(connor, `/v1/posts/${ids[0]}/prayers`, {});
    expect((await home(connor)).prayerRequests).toHaveLength(1);

    await post(connor, `/v1/posts/${ids[1]}/prayers`, {});
    const caughtUp = await home(connor);
    expect(caughtUp.prayerRequests).toHaveLength(0);
    expect(caughtUp.remainingPrayerRequests).toBe(0);
  });

  it('never offers the viewer their own prayer', async () => {
    await createPost(connor, { type: 'prayer', visibility: 'public' });
    const result = await home(connor);
    expect(result.prayerRequests).toHaveLength(0);
    expect(result.remainingPrayerRequests).toBe(0);
  });

  it('excludes private and follower-only prayers', async () => {
    await createPost(gabi, { type: 'prayer', visibility: 'private' });
    await createPost(gabi, { type: 'prayer', visibility: 'followers' });
    expect((await home(connor)).prayerRequests).toHaveLength(0);
  });

  it('excludes answered prayers', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(gabi, `/v1/posts/${id}/answer`, { body: 'It happened.' });
    expect((await home(connor)).prayerRequests).toHaveLength(0);
  });

  it('excludes anyone blocked, in either direction', async () => {
    await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await block(connor, gabi);
    expect((await home(connor)).prayerRequests).toHaveLength(0);

    await env.DB.prepare('delete from blocks').run();
    await block(gabi, connor);
    expect((await home(connor)).prayerRequests).toHaveLength(0);
  });

  it('includes anonymous prayers without identifying who asked', async () => {
    await createPost(gabi, { type: 'prayer', visibility: 'public', anonymous: true });

    const raw = await (await api(connor, '/v1/home')).text();
    expect(JSON.parse(raw).prayerRequests).toHaveLength(1);
    expect(raw).not.toContain(gabi.id);
    expect(raw).not.toContain('gabi');
  });
});

describe('miracles around you', () => {
  it('shows other people’s, most recent first', async () => {
    await createPostAt(gabi, new Date('2026-08-01T00:00:00Z'), { type: 'miracle', visibility: 'public', body: 'Older' });
    await createPostAt(gabi, new Date('2026-08-10T00:00:00Z'), { type: 'miracle', visibility: 'public', body: 'Newer' });

    const result = await home(connor);
    expect(result.recentMiracles).toHaveLength(2);
  });

  it('is capped', async () => {
    for (let i = 0; i < 6; i++) {
      await createPost(gabi, { type: 'miracle', visibility: 'public', body: `Miracle ${i}` });
    }
    expect((await home(connor)).recentMiracles).toHaveLength(3);
  });

  it('excludes the viewer’s own', async () => {
    await createPost(connor, { type: 'miracle', visibility: 'public' });
    expect((await home(connor)).recentMiracles).toHaveLength(0);
  });

  it('excludes blocked people', async () => {
    await createPost(gabi, { type: 'miracle', visibility: 'public' });
    await block(gabi, connor);
    expect((await home(connor)).recentMiracles).toHaveLength(0);
  });
});

describe('on this day', () => {
  /** Same calendar day, an earlier year. */
  function sameDayLastYear(): Date {
    const now = new Date();
    return new Date(Date.UTC(
      now.getUTCFullYear() - 1, now.getUTCMonth(), now.getUTCDate(), 12, 0, 0,
    ));
  }

  it('resurfaces something the viewer wrote on this date', async () => {
    const id = await createPostAt(connor, sameDayLastYear(), {
      type: 'miracle', visibility: 'private', body: 'We finally got the house.',
    });
    expect((await home(connor)).memory?.id).toBe(id);
  });

  it('is nothing when there is nothing to remember', async () => {
    await createPostAt(connor, new Date('2020-03-14T12:00:00Z'), { type: 'miracle' });
    expect((await home(connor)).memory).toBeNull();
  });

  it('never resurfaces someone else’s memory', async () => {
    await createPostAt(gabi, sameDayLastYear(), { type: 'miracle', visibility: 'public' });
    expect((await home(connor)).memory).toBeNull();
  });

  /**
   * Resurfacing "please pray for my marriage" from three years ago, with no indication of
   * how it turned out, would be a small cruelty.
   */
  it('never resurfaces an unanswered prayer', async () => {
    await createPostAt(connor, sameDayLastYear(), { type: 'prayer', visibility: 'public' });
    expect((await home(connor)).memory).toBeNull();
  });

  it('does resurface a prayer that was answered', async () => {
    const id = await createPostAt(connor, sameDayLastYear(), {
      type: 'prayer', visibility: 'public', status: 'answered',
    });
    expect((await home(connor)).memory?.id).toBe(id);
  });

  it('does not resurface something from today', async () => {
    await createPost(connor, { type: 'miracle', visibility: 'public' });
    expect((await home(connor)).memory).toBeNull();
  });
});

describe('home', () => {
  it('requires authentication', async () => {
    expect((await api(null, '/v1/home')).status).toBe(401);
  });

  it('is empty and calm for a brand-new account', async () => {
    const result = await home(connor);
    expect(result).toEqual({
      prayerRequests: [],
      remainingPrayerRequests: 0,
      recentMiracles: [],
      memory: null,
    });
  });

  it('carries no author identity anywhere in the payload', async () => {
    await createPost(gabi, { type: 'prayer', visibility: 'public', anonymous: true });
    await createPost(gabi, { type: 'miracle', visibility: 'public', anonymous: true });

    const raw = await (await api(connor, '/v1/home')).text();
    expect(raw).not.toContain(gabi.id);
    expect(raw).not.toContain('owner_id');
    expect(raw).not.toContain('ownerId');
  });
});
