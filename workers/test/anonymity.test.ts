import { describe, it, expect, beforeEach } from 'vitest';
import { env } from 'cloudflare:test';
import {
  api,
  createAccount,
  createPost,
  del,
  post,
  resetDatabase,
  type TestAccount,
} from './helpers';

/**
 * Anonymous means anonymous to other users, never to the platform (rules 8 and 9).
 *
 * These tests exist because this is the failure that would matter most. The content people
 * post anonymously is the content they could not put their name to — illness, marriage,
 * sexuality, money, addiction, a death in the family. On D1 the only thing preventing
 * exposure is that the author's identity is not in the row anyone reads, so that property
 * is asserted directly rather than assumed.
 */

let alice: TestAccount;
let bob: TestAccount;
let anonymousPostId: string;

beforeEach(async () => {
  await resetDatabase();
  alice = await createAccount('alice');
  bob = await createAccount('bob');
  anonymousPostId = await createPost(alice, { visibility: 'public', anonymous: true });
});

describe('an anonymous post', () => {
  it('is readable, with no author attached', async () => {
    const response = await api(bob, `/v1/posts/${anonymousPostId}`);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ displayProfile: null });
  });

  /**
   * The strongest assertion available: the author's account id appears nowhere in the
   * serialized bytes, whatever shape the response happens to take.
   */
  it('never carries the author’s id anywhere in the payload', async () => {
    // The account id is internal and must not appear in any response, including Alice's
    // own profile card — nothing a client needs is keyed on it.
    const everyPath = [
      `/v1/posts/${anonymousPostId}`,
      '/v1/feed',
      `/v1/posts/${anonymousPostId}/comments`,
      '/v1/profiles/alice',
      '/v1/profiles/alice/posts',
    ];

    for (const path of everyPath) {
      const body = await (await api(bob, path)).text();
      expect(body, `${path} leaked the author id`).not.toContain(alice.id);
    }

    // The username is a different matter: asking for Alice's profile legitimately returns
    // it. What must never happen is her name appearing anywhere the anonymous post is
    // surfaced.
    const pathsShowingThePost = [
      `/v1/posts/${anonymousPostId}`,
      '/v1/feed',
      '/v1/profiles/alice/posts',
    ];

    for (const path of pathsShowingThePost) {
      const body = await (await api(bob, path)).text();
      expect(body, `${path} attributed the anonymous post`).not.toContain('alice');
    }
  });

  it('does not appear on its author’s public profile timeline', async () => {
    const response = await api(bob, '/v1/profiles/alice/posts');
    expect((await response.json() as { items: unknown[] }).items).toHaveLength(0);
  });

  it('still belongs to its author in their own journal', async () => {
    const response = await api(alice, '/v1/me/journal');
    const { items } = await response.json() as { items: { id: string; isMine: boolean }[] };

    expect(items).toHaveLength(1);
    expect(items[0]!.id).toBe(anonymousPostId);
    expect(items[0]!.isMine).toBe(true);
  });

  it('is still editable and deletable by its author', async () => {
    expect((await del(alice, `/v1/posts/${anonymousPostId}`)).status).toBe(204);
  });

  it('cannot be edited by anyone else', async () => {
    const response = await api(bob, `/v1/posts/${anonymousPostId}`, {
      method: 'PATCH',
      body: JSON.stringify({ version: 1, body: 'not yours', visibility: 'public' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(response.status).toBe(403);
  });

  /**
   * Commenting and praying are done under one's own name. That is fine — the commenters
   * are not the author, so the thread must not become a way to work out who is.
   */
  it('is not identified through its own comment thread', async () => {
    await post(bob, `/v1/posts/${anonymousPostId}/comments`, { body: 'praying for you' });

    const body = await (await api(bob, `/v1/posts/${anonymousPostId}/comments`)).text();
    expect(body).toContain('bob');
    expect(body).not.toContain(alice.id);
  });

  it('is still owned by the author in the database', async () => {
    // The platform knows. That is the whole point of the split: anonymous to users,
    // accountable to moderation.
    const row = await env.DB.prepare('select owner_id from post_authorship where post_id = ?')
      .bind(anonymousPostId)
      .first<{ owner_id: string }>();

    expect(row?.owner_id).toBe(alice.id);
  });
});

describe('the serialized shape', () => {
  it('exposes no ownership field at all', async () => {
    const response = await api(bob, `/v1/posts/${anonymousPostId}`);
    const payload = await response.json() as Record<string, unknown>;

    for (const forbidden of ['ownerId', 'owner_id', 'authorId', 'author_id', 'accountId']) {
      expect(Object.keys(payload)).not.toContain(forbidden);
    }
  });

  /** A named post does carry its display profile — anonymity is opt-in, not the default. */
  it('still attributes a non-anonymous post', async () => {
    const named = await createPost(alice, { visibility: 'public', anonymous: false });
    const response = await api(bob, `/v1/posts/${named}`);

    expect(await response.json()).toMatchObject({
      displayProfile: { username: 'alice', displayName: 'alice' },
    });
  });
});

describe('posting anonymously through the API', () => {
  it('stores no display profile', async () => {
    const response = await post(alice, '/v1/posts', {
      type: 'prayer',
      body: 'Please pray for my marriage.',
      visibility: 'public',
      anonymous: true,
    });
    const { id } = await response.json() as { id: string };

    const row = await env.DB.prepare(
      'select display_profile_id from posts where id = ?',
    )
      .bind(id)
      .first<{ display_profile_id: string | null }>();

    expect(row?.display_profile_id).toBeNull();
  });

  /** Private and anonymous together is meaningless, and the schema forbids it. */
  it('refuses a private anonymous post with an explanation', async () => {
    const response = await post(alice, '/v1/posts', {
      type: 'prayer',
      body: 'x',
      visibility: 'private',
      anonymous: true,
    });
    expect(response.status).toBe(422);
  });
});
