import { describe, it, expect, beforeEach } from 'vitest';
import { env } from 'cloudflare:test';
import {
  api,
  block,
  createAccount,
  createPost,
  del,
  follow,
  post,
  resetDatabase,
  type TestAccount,
} from './helpers';

/**
 * The social half, and the things it deliberately is not.
 *
 * Saving is a private bookmark, never a like. Discovery is a search box, never a ranked
 * list of suggestions. Nothing anywhere reports a follower count. Blocks outrank follows.
 */

let connor: TestAccount;
let gabi: TestAccount;

beforeEach(async () => {
  await resetDatabase();
  connor = await createAccount('connor');
  gabi = await createAccount('gabi');
});

describe('saving', () => {
  it('keeps a private list', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });

    expect(await (await post(connor, `/v1/posts/${id}/save`, {})).json()).toEqual({ saved: true });

    const saved = await (await api(connor, '/v1/me/saved')).json() as { items: { id: string }[] };
    expect(saved.items.map((item) => item.id)).toEqual([id]);
  });

  it('is idempotent', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});
    await post(connor, `/v1/posts/${id}/save`, {});

    const row = await env.DB.prepare('select count(*) as n from saved_posts').first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it('can be undone', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});

    expect(await (await del(connor, `/v1/posts/${id}/save`)).json()).toEqual({ saved: false });
    const saved = await (await api(connor, '/v1/me/saved')).json() as { items: unknown[] };
    expect(saved.items).toHaveLength(0);
  });

  /**
   * A bookmark is a pointer, not a copy. Saving something public must not grant permanent
   * access to it.
   */
  it('drops out of the list when the author makes it private', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});

    await env.DB.prepare("update posts set visibility = 'private' where id = ?").bind(id).run();

    const saved = await (await api(connor, '/v1/me/saved')).json() as { items: unknown[] };
    expect(saved.items).toHaveLength(0);
  });

  it('drops out of the list after a block, in either direction', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});
    await block(gabi, connor);

    const saved = await (await api(connor, '/v1/me/saved')).json() as { items: unknown[] };
    expect(saved.items).toHaveLength(0);
  });

  it('disappears when the post is deleted', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});
    await del(gabi, `/v1/posts/${id}`);

    const saved = await (await api(connor, '/v1/me/saved')).json() as { items: unknown[] };
    expect(saved.items).toHaveLength(0);
  });

  /** Saving must not become a way to probe for posts you cannot see. */
  it('cannot save something invisible', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'private' });
    expect((await post(connor, `/v1/posts/${id}/save`, {})).status).toBe(404);
  });

  /**
   * Saving is not a like. The author learns nothing, and there is no count anywhere.
   */
  it('tells the author nothing', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });
    await post(connor, `/v1/posts/${id}/save`, {});

    const authorView = await (await api(gabi, `/v1/posts/${id}`)).text();
    expect(authorView).not.toContain('saveCount');
    expect(authorView).not.toContain(connor.id);

    const notifications = await env.DB.prepare(
      'select count(*) as n from notification_events',
    ).first<{ n: number }>();
    expect(notifications?.n).toBe(0);
  });

  it('reports whether the viewer has saved a post', async () => {
    const id = await createPost(gabi, { type: 'prayer', visibility: 'public' });

    expect((await (await api(connor, `/v1/posts/${id}`)).json() as { isSaved: boolean }).isSaved)
      .toBe(false);

    await post(connor, `/v1/posts/${id}/save`, {});
    expect((await (await api(connor, `/v1/posts/${id}`)).json() as { isSaved: boolean }).isSaved)
      .toBe(true);
  });

  it('is private to the viewer', async () => {
    const id = await createPost(connor, { type: 'miracle', visibility: 'public' });
    await post(gabi, `/v1/posts/${id}/save`, {});

    const mine = await (await api(connor, '/v1/me/saved')).json() as { items: unknown[] };
    expect(mine.items).toHaveLength(0);
  });
});

describe('finding people', () => {
  interface People {
    items: { username: string; displayName: string; isFollowing: boolean }[];
  }

  async function search(account: TestAccount, query: string): Promise<People> {
    return (await api(account, `/v1/people?q=${encodeURIComponent(query)}`)).json() as Promise<People>;
  }

  it('finds someone by the start of their username', async () => {
    const result = await search(connor, 'gab');
    expect(result.items.map((item) => item.username)).toEqual(['gabi']);
  });

  it('finds someone by display name', async () => {
    await createAccount('quiet_one');
    await env.DB.prepare("update profiles set display_name = 'Marianne' where username = 'quiet_one'").run();

    const result = await search(connor, 'Maria');
    expect(result.items.map((item) => item.username)).toEqual(['quiet_one']);
  });

  it('is case-insensitive', async () => {
    expect((await search(connor, 'GAB')).items).toHaveLength(1);
  });

  it('never returns the viewer', async () => {
    expect((await search(connor, 'connor')).items).toHaveLength(0);
  });

  it('hides blocked people in both directions', async () => {
    await block(connor, gabi);
    expect((await search(connor, 'gab')).items).toHaveLength(0);
    expect((await search(gabi, 'con')).items).toHaveLength(0);
  });

  it('hides suspended accounts', async () => {
    await env.DB.prepare("update accounts set status = 'suspended' where id = ?")
      .bind(gabi.id).run();
    expect((await search(connor, 'gab')).items).toHaveLength(0);
  });

  it('reports whether the viewer already follows them', async () => {
    expect((await search(connor, 'gab')).items[0]!.isFollowing).toBe(false);
    await follow(connor, gabi);
    expect((await search(connor, 'gab')).items[0]!.isFollowing).toBe(true);
  });

  it('needs something to go on', async () => {
    expect((await search(connor, 'g')).items).toHaveLength(0);
    expect((await search(connor, '')).items).toHaveLength(0);
  });

  it('treats wildcards as literal characters', async () => {
    expect((await search(connor, '%%')).items).toHaveLength(0);
    expect((await search(connor, '__')).items).toHaveLength(0);
  });

  /**
   * The line between a directory and a growth mechanic. Discovery answers a question
   * somebody asked; it never volunteers a ranked list of accounts (rule 13).
   */
  it('reports no popularity metric of any kind', async () => {
    await createPost(gabi, { type: 'miracle', visibility: 'public' });
    await follow(connor, gabi);

    const raw = await (await api(connor, '/v1/people?q=gab')).text();
    for (const forbidden of ['followerCount', 'followingCount', 'postCount', 'prayerCount', 'score', 'rank']) {
      expect(raw).not.toContain(forbidden);
    }
  });

  it('never exposes an account id', async () => {
    const raw = await (await api(connor, '/v1/people?q=gab')).text();
    expect(raw).not.toContain(gabi.id);
  });
});

describe('profiles', () => {
  interface Profile {
    username: string;
    isMe: boolean;
    isFollowing: boolean;
  }

  it('reports whether the viewer follows them', async () => {
    const before = await (await api(connor, '/v1/profiles/gabi')).json() as Profile;
    expect(before.isFollowing).toBe(false);

    await post(connor, '/v1/follows', { username: 'gabi' });

    const after = await (await api(connor, '/v1/profiles/gabi')).json() as Profile;
    expect(after.isFollowing).toBe(true);
  });

  it('carries no follower count', async () => {
    await follow(connor, gabi);
    const raw = await (await api(connor, '/v1/profiles/gabi')).text();

    for (const forbidden of ['followerCount', 'followingCount', 'followers', 'postCount']) {
      expect(raw).not.toContain(forbidden);
    }
  });

  it('knows its own', async () => {
    const mine = await (await api(connor, '/v1/profiles/connor')).json() as Profile;
    expect(mine.isMe).toBe(true);
  });
});

describe('follower-only content', () => {
  it('becomes visible on following, and invisible again on unfollowing', async () => {
    const id = await createPost(gabi, { type: 'miracle', visibility: 'followers' });

    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(404);

    await post(connor, '/v1/follows', { username: 'gabi' });
    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(200);

    await del(connor, '/v1/follows/gabi');
    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(404);
  });

  /** A block outranks a follow, whichever came first. */
  it('is cut off by a block even for an existing follower', async () => {
    const id = await createPost(gabi, { type: 'miracle', visibility: 'followers' });
    await post(connor, '/v1/follows', { username: 'gabi' });
    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(200);

    await post(gabi, '/v1/blocks', { username: 'connor' });
    expect((await api(connor, `/v1/posts/${id}`)).status).toBe(404);
  });
});

describe('reporting a person', () => {
  /** Account ids are internal, so a profile is reported by the only handle a client has. */
  it('is reported by username', async () => {
    const response = await post(connor, '/v1/reports', {
      subjectType: 'profile',
      subjectId: 'gabi',
      category: 'impersonation',
    });
    expect(response.status).toBe(201);

    // The case keys on the account id, which survives a username change.
    const row = await env.DB.prepare(
      "select subject_id from moderation_cases where subject_type = 'profile'",
    ).first<{ subject_id: string }>();
    expect(row?.subject_id).toBe(gabi.id);
  });

  it('refuses an unknown username without confirming anything', async () => {
    const response = await post(connor, '/v1/reports', {
      subjectType: 'profile',
      subjectId: 'nobody_here',
      category: 'spam',
    });
    expect(response.status).toBe(404);
  });

  it('refuses to report yourself', async () => {
    const response = await post(connor, '/v1/reports', {
      subjectType: 'profile',
      subjectId: 'connor',
      category: 'spam',
    });
    expect(response.status).toBe(422);
  });

  it('refuses to report someone already blocked, the same way viewing them is refused', async () => {
    await block(connor, gabi);
    const response = await post(connor, '/v1/reports', {
      subjectType: 'profile',
      subjectId: 'gabi',
      category: 'harassment',
    });
    expect(response.status).toBe(404);
  });
});

describe('what the product deliberately does not have', () => {
  /**
   * Not an oversight. Direct messages are out of V1 (rule 12), and so is anything that
   * turns support into a scoreboard (rule 13).
   */
  it.each([
    '/v1/messages',
    '/v1/dms',
    '/v1/conversations',
    '/v1/trending',
    '/v1/leaderboard',
    '/v1/suggestions',
    '/v1/discover/trending',
  ])('%s does not exist', async (path) => {
    expect((await api(connor, path)).status).toBe(404);
  });
});
