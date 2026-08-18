import { describe, it, expect, beforeEach } from 'vitest';
import {
  api,
  block,
  createAccount,
  createPost,
  del,
  resetDatabase,
  follow,
  patch,
  post,
  suspend,
  type TestAccount,
} from './helpers';

/**
 * The adversarial matrix from docs/database.md.
 *
 * On Postgres these outcomes would be guaranteed by RLS policies. On D1 they are
 * guaranteed by this file and the code it exercises — nothing else. A failing test here is
 * never fixed by loosening a check (rule 6).
 */

let alice: TestAccount;
let bob: TestAccount;

beforeEach(async () => {
  await resetDatabase();
  alice = await createAccount('alice');
  bob = await createAccount('bob');
});

describe('authentication', () => {
  it('refuses an anonymous request', async () => {
    const response = await api(null, '/v1/feed');
    expect(response.status).toBe(401);
  });

  it('refuses a forged token', async () => {
    const response = await api({ ...alice, token: 'not.a.token' }, '/v1/feed');
    expect(response.status).toBe(401);
  });

  /** A token signed with the wrong key must not be accepted just because it parses. */
  it('refuses a well-formed token signed with the wrong key', async () => {
    const { signAccessToken } = await import('../src/auth/tokens');
    const forged = await signAccessToken('a-different-signing-key', alice.id);
    const response = await api({ ...alice, token: forged }, '/v1/feed');
    expect(response.status).toBe(401);
  });

  it('refuses an expired token', async () => {
    const { signAccessToken } = await import('../src/auth/tokens');
    const { env } = await import('cloudflare:test');
    const stale = await signAccessToken(
      env.SESSION_SIGNING_KEY,
      alice.id,
      Date.now() - 60 * 60 * 1000,
    );
    const response = await api({ ...alice, token: stale }, '/v1/feed');
    expect(response.status).toBe(401);
  });

  /** A suspension must bite immediately, not when the access token happens to expire. */
  it('refuses a suspended account holding a valid token', async () => {
    await suspend(alice);
    const response = await api(alice, '/v1/feed');
    expect(response.status).toBe(401);
  });
});

describe('private posts', () => {
  it('the owner can read their own', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    const response = await api(alice, `/v1/posts/${id}`);
    expect(response.status).toBe(200);
  });

  /** 404, not 403 — a 403 would confirm that a private post with this id exists. */
  it('nobody else can read it, and is not told it exists', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    const response = await api(bob, `/v1/posts/${id}`);
    expect(response.status).toBe(404);
  });

  it('is absent from the public feed', async () => {
    await createPost(alice, { visibility: 'private' });
    const response = await api(bob, '/v1/feed');
    expect(await response.json()).toMatchObject({ items: [] });
  });

  it('cannot be reached through its author’s profile timeline', async () => {
    await createPost(alice, { visibility: 'private' });
    const response = await api(bob, `/v1/profiles/alice/posts`);
    expect(await response.json()).toMatchObject({ items: [] });
  });

  it('does not accept prayers or comments', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    expect((await post(alice, `/v1/posts/${id}/prayers`, {})).status).toBe(403);
    expect((await post(alice, `/v1/posts/${id}/comments`, { body: 'hi' })).status).toBe(403);
  });
});

describe('follower-only posts', () => {
  it('an accepted follower can read it', async () => {
    const id = await createPost(alice, { visibility: 'followers' });
    await follow(bob, alice);
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(200);
  });

  it('a stranger cannot', async () => {
    const id = await createPost(alice, { visibility: 'followers' });
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(404);
  });

  /** Following is directional. Alice following Bob does not let Bob read Alice's posts. */
  it('following in the wrong direction does not grant access', async () => {
    const id = await createPost(alice, { visibility: 'followers' });
    await follow(alice, bob);
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(404);
  });

  it('appears on the profile timeline only for followers', async () => {
    await createPost(alice, { visibility: 'followers' });

    const stranger = await api(bob, '/v1/profiles/alice/posts');
    expect((await stranger.json() as { items: unknown[] }).items).toHaveLength(0);

    await follow(bob, alice);
    const follower = await api(bob, '/v1/profiles/alice/posts');
    expect((await follower.json() as { items: unknown[] }).items).toHaveLength(1);
  });
});

describe('blocks', () => {
  it('hide public content from the blocked person', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    await block(alice, bob);
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(404);
  });

  /** A block is mutual. It does not matter who pressed the button. */
  it('hide content in both directions', async () => {
    const alicePost = await createPost(alice, { visibility: 'public' });
    const bobPost = await createPost(bob, { visibility: 'public' });
    await block(alice, bob);

    expect((await api(bob, `/v1/posts/${alicePost}`)).status).toBe(404);
    expect((await api(alice, `/v1/posts/${bobPost}`)).status).toBe(404);
  });

  it('outrank an existing follow', async () => {
    const id = await createPost(alice, { visibility: 'followers' });
    await follow(bob, alice);
    await block(alice, bob);
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(404);
  });

  it('remove the follow edge in both directions', async () => {
    await follow(bob, alice);
    await follow(alice, bob);
    await post(alice, '/v1/blocks', { username: 'bob' });

    const id = await createPost(alice, { visibility: 'followers' });
    expect((await api(bob, `/v1/posts/${id}`)).status).toBe(404);
  });

  it('remove each other from the feed', async () => {
    await createPost(alice, { visibility: 'public' });
    await block(bob, alice);

    const response = await api(bob, '/v1/feed');
    expect((await response.json() as { items: unknown[] }).items).toHaveLength(0);
  });

  it('hide the profile itself, without confirming it exists', async () => {
    await block(alice, bob);
    expect((await api(bob, '/v1/profiles/alice')).status).toBe(404);
  });

  it('stop a blocked person from following their way back in', async () => {
    await block(alice, bob);
    expect((await post(bob, '/v1/follows', { username: 'alice' })).status).toBe(404);
  });

  it('hide comments from a blocked author', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    await post(bob, `/v1/posts/${id}/comments`, { body: 'encouragement' });

    const before = await api(alice, `/v1/posts/${id}/comments`);
    expect((await before.json() as { items: unknown[] }).items).toHaveLength(1);

    await block(alice, bob);
    const after = await api(alice, `/v1/posts/${id}/comments`);
    expect((await after.json() as { items: unknown[] }).items).toHaveLength(0);
  });
});

describe('ownership', () => {
  /** Visible but not yours: 403 is correct here, because existence is not a secret. */
  it('refuses an edit of somebody else’s public post with 403, not 404', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    const response = await patch(bob, `/v1/posts/${id}`, {
      version: 1,
      body: 'edited by Bob',
      visibility: 'public',
    });
    expect(response.status).toBe(403);
  });

  /** Invisible and not yours: 404, so the refusal reveals nothing. */
  it('refuses an edit of an invisible post with 404', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    const response = await patch(bob, `/v1/posts/${id}`, {
      version: 1,
      body: 'edited by Bob',
      visibility: 'public',
    });
    expect(response.status).toBe(404);
  });

  it('refuses a delete by anyone but the owner', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    expect((await del(bob, `/v1/posts/${id}`)).status).toBe(403);
    expect((await api(alice, `/v1/posts/${id}`)).status).toBe(200);
  });

  it('lets the owner edit and delete', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    expect(
      (await patch(alice, `/v1/posts/${id}`, {
        version: 1,
        body: 'clearer wording',
        visibility: 'public',
      })).status,
    ).toBe(200);
    expect((await del(alice, `/v1/posts/${id}`)).status).toBe(204);
    expect((await api(alice, `/v1/posts/${id}`)).status).toBe(404);
  });

  it('rejects a stale write instead of silently overwriting', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    await patch(alice, `/v1/posts/${id}`, { version: 1, body: 'first', visibility: 'public' });

    const stale = await patch(alice, `/v1/posts/${id}`, {
      version: 1,
      body: 'from another device',
      visibility: 'public',
    });
    expect(stale.status).toBe(409);
  });

  it('never lets one account read another’s journal', async () => {
    await createPost(alice, { visibility: 'private' });
    const response = await api(bob, '/v1/me/journal');
    expect((await response.json() as { items: unknown[] }).items).toHaveLength(0);
  });
});

describe('prayer responses', () => {
  it('records one per person and is idempotent on a double tap', async () => {
    const id = await createPost(alice, { visibility: 'public' });

    const first = await post(bob, `/v1/posts/${id}/prayers`, {});
    expect(await first.json()).toMatchObject({ prayerResponseCount: 1, hasPrayed: true });

    const second = await post(bob, `/v1/posts/${id}/prayers`, {});
    expect(await second.json()).toMatchObject({ prayerResponseCount: 1, hasPrayed: true });
  });

  it('cannot be left on a post the viewer cannot see', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    expect((await post(bob, `/v1/posts/${id}/prayers`, {})).status).toBe(404);
  });

  it('cannot be left on a removed post', async () => {
    const id = await createPost(alice, { visibility: 'public', status: 'removed' });
    expect((await post(bob, `/v1/posts/${id}/prayers`, {})).status).toBe(404);
  });

  it('can be withdrawn', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    await post(bob, `/v1/posts/${id}/prayers`, {});

    const response = await del(bob, `/v1/posts/${id}/prayers`);
    expect(await response.json()).toMatchObject({ prayerResponseCount: 0, hasPrayed: false });
  });
});

describe('comments', () => {
  it('are refused on a post the viewer cannot see', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    expect((await post(bob, `/v1/posts/${id}/comments`, { body: 'hi' })).status).toBe(404);
    expect((await api(bob, `/v1/posts/${id}/comments`)).status).toBe(404);
  });

  it('can only be deleted by their author', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    const created = await post(bob, `/v1/posts/${id}/comments`, { body: 'thinking of you' });
    const { id: commentId } = await created.json() as { id: string };

    expect((await del(alice, `/v1/comments/${commentId}`)).status).toBe(404);
    expect((await del(bob, `/v1/comments/${commentId}`)).status).toBe(204);
  });
});

describe('reports', () => {
  it('cannot be used to probe for posts the reporter cannot see', async () => {
    const id = await createPost(alice, { visibility: 'private' });
    const response = await post(bob, '/v1/reports', {
      subjectType: 'post',
      subjectId: id,
      category: 'harassment',
    });
    expect(response.status).toBe(404);
  });

  it('accepts one report per person per subject', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    expect(
      (await post(bob, '/v1/reports', {
        subjectType: 'post',
        subjectId: id,
        category: 'harassment',
      })).status,
    ).toBe(201);

    expect(
      (await post(bob, '/v1/reports', {
        subjectType: 'post',
        subjectId: id,
        category: 'spam',
      })).status,
    ).toBe(409);
  });

  /** The reporter learns nothing about moderation state — not the case, not the count. */
  it('disclose nothing about the resulting case', async () => {
    const id = await createPost(alice, { visibility: 'public' });
    const response = await post(bob, '/v1/reports', {
      subjectType: 'post',
      subjectId: id,
      category: 'harassment',
    });
    expect(await response.json()).toEqual({ submitted: true });
  });
});

describe('tables with no client surface', () => {
  /**
   * Not a policy that refuses these — there is simply no route. A table you cannot address
   * is a stronger guarantee than one you can address and are denied.
   */
  it.each([
    '/v1/moderation/cases',
    '/v1/moderation-cases',
    '/v1/post_authorship',
    '/v1/refresh_tokens',
    '/v1/user_entitlements',
    '/v1/accounts',
  ])('%s is unreachable', async (path) => {
    expect((await api(alice, path)).status).toBe(404);
  });
});

describe('idempotency', () => {
  it('replays the original result instead of creating a second post', async () => {
    const key = 'retry-key-0001';
    const first = await post(
      alice,
      '/v1/posts',
      { type: 'prayer', body: 'Please pray.', visibility: 'public' },
      { headers: { 'Idempotency-Key': key } },
    );
    const second = await post(
      alice,
      '/v1/posts',
      { type: 'prayer', body: 'Please pray.', visibility: 'public' },
      { headers: { 'Idempotency-Key': key } },
    );

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect((await second.json() as { id: string }).id).toBe(
      (await first.json() as { id: string }).id,
    );

    const journal = await api(alice, '/v1/me/journal');
    expect((await journal.json() as { items: unknown[] }).items).toHaveLength(1);
  });

  /** Guessing somebody else's key must not return their record. */
  it('refuses a key belonging to another account', async () => {
    const key = 'shared-key-0002';
    await post(
      alice,
      '/v1/posts',
      { type: 'prayer', body: 'Please pray.', visibility: 'public' },
      { headers: { 'Idempotency-Key': key } },
    );

    const response = await post(
      bob,
      '/v1/posts',
      { type: 'prayer', body: 'Mine now.', visibility: 'public' },
      { headers: { 'Idempotency-Key': key } },
    );
    expect(response.status).toBe(403);
  });
});
