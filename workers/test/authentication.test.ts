import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { env } from 'cloudflare:test';
import { api, post, resetDatabase } from './helpers';
import {
  createAppleFixture,
  installFailingJWKS,
  TEST_CLIENT_ID,
  type AppleFixture,
} from './apple-fixture';
import { sha256Hex } from '../src/auth/tokens';

/**
 * Sign in with Apple, session rotation, profile claiming and account deletion.
 *
 * Authentication is where a mistake is unrecoverable: everything else in the authorization
 * layer depends on the viewer being who the token says. These tests attack the token
 * itself — wrong audience, wrong issuer, expired, tampered, unknown key — because each of
 * those checks is one `if` away from being an authentication bypass.
 */

let apple: AppleFixture;

beforeEach(async () => {
  await resetDatabase();
  apple = await createAppleFixture();
  apple.install();
});

afterEach(() => {
  apple.uninstall();
});

interface SessionResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  isNewAccount: boolean;
  profile: { username: string } | null;
}

async function signIn(overrides = {}, body = {}): Promise<Response> {
  return post(null, '/v1/auth/apple', {
    identityToken: await apple.mint(overrides),
    ...body,
  });
}

describe('sign in with Apple', () => {
  it('creates an account on first sign-in, with no profile yet', async () => {
    const response = await signIn();
    expect(response.status).toBe(201);

    const session = await response.json() as SessionResponse;
    expect(session.isNewAccount).toBe(true);
    expect(session.accessToken).toBeTruthy();
    expect(session.refreshToken).toBeTruthy();
    // Onboarding has not happened yet, so the app knows to ask for a username.
    expect(session.profile).toBeNull();
  });

  it('returns the same account on a second sign-in', async () => {
    const first = await (await signIn()).json() as SessionResponse;
    const second = await signIn();

    expect(second.status).toBe(200);
    expect((await second.json() as SessionResponse).isNewAccount).toBe(false);

    const accounts = await env.DB.prepare('select count(*) as n from accounts').first<{ n: number }>();
    expect(accounts?.n).toBe(1);
    expect(first.accessToken).toBeTruthy();
  });

  it('gives the new account a free entitlement', async () => {
    await signIn();
    const row = await env.DB.prepare('select entitlement, status from user_entitlements')
      .first<{ entitlement: string; status: string }>();
    expect(row).toMatchObject({ entitlement: 'free', status: 'active' });
  });

  it('stores a private-relay email as such', async () => {
    await signIn({ email: 'x@privaterelay.appleid.com', is_private_email: 'true' });
    const row = await env.DB.prepare(
      'select email, email_is_private_relay from auth_identities',
    ).first<{ email: string; email_is_private_relay: number }>();

    expect(row?.email).toBe('x@privaterelay.appleid.com');
    expect(row?.email_is_private_relay).toBe(1);
  });

  /**
   * The audience check. Without it, an identity token minted for any other app using Sign
   * in with Apple would authenticate here — the single most damaging thing to get wrong.
   */
  it('refuses a token issued for a different app', async () => {
    const response = await signIn({ aud: 'com.someone.else.app' });
    expect(response.status).toBe(401);
  });

  it('refuses a token from a different issuer', async () => {
    const response = await signIn({ iss: 'https://accounts.google.com' });
    expect(response.status).toBe(401);
  });

  it('refuses an expired token', async () => {
    const past = Math.floor(Date.now() / 1000) - 3600;
    const response = await signIn({ iat: past - 600, exp: past });
    expect(response.status).toBe(401);
  });

  it('refuses a token with no subject', async () => {
    const response = await signIn({ sub: '' });
    expect(response.status).toBe(401);
  });

  it('refuses a token whose signature has been tampered with', async () => {
    const token = await apple.mint();
    const [header, payload] = token.split('.') as [string, string, string];
    const forged = `${header}.${payload}.${'A'.repeat(342)}`;

    const response = await post(null, '/v1/auth/apple', { identityToken: forged });
    expect(response.status).toBe(401);
  });

  /** Swapping the payload for another subject must not survive signature verification. */
  it('refuses a token whose payload has been swapped', async () => {
    const token = await apple.mint();
    const [header, , signature] = token.split('.') as [string, string, string];
    const forgedPayload = btoa(
      JSON.stringify({
        iss: 'https://appleid.apple.com',
        aud: TEST_CLIENT_ID,
        sub: 'someone.else.9999',
        exp: Math.floor(Date.now() / 1000) + 600,
      }),
    )
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

    const response = await post(null, '/v1/auth/apple', {
      identityToken: `${header}.${forgedPayload}.${signature}`,
    });
    expect(response.status).toBe(401);
  });

  it.each([
    ['not a token', 'nonsense'],
    ['two segments', 'a.b'],
    ['empty', ''],
  ])('refuses a malformed token (%s)', async (_label, identityToken) => {
    const response = await post(null, '/v1/auth/apple', { identityToken });
    expect(response.status).toBeGreaterThanOrEqual(401);
  });

  it('fails closed when Apple cannot be reached', async () => {
    const token = await apple.mint();
    apple.uninstall();
    const restore = installFailingJWKS();

    try {
      const response = await post(null, '/v1/auth/apple', { identityToken: token });
      expect(response.status).toBe(401);
    } finally {
      restore();
    }
  });
});

describe('nonce', () => {
  it('accepts a token whose nonce matches', async () => {
    const nonce = 'client-generated-nonce';
    const response = await signIn({ nonce: await sha256Hex(nonce) }, { nonce });
    expect(response.status).toBe(201);
  });

  /** Replay protection: a captured token cannot be reused with a different nonce. */
  it('refuses a token whose nonce does not match', async () => {
    const response = await signIn(
      { nonce: await sha256Hex('a-different-nonce') },
      { nonce: 'client-generated-nonce' },
    );
    expect(response.status).toBe(401);
  });
});

describe('session rotation', () => {
  async function newSession(): Promise<SessionResponse> {
    return (await signIn()).json() as Promise<SessionResponse>;
  }

  it('exchanges a refresh token for a new pair', async () => {
    const session = await newSession();
    const response = await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    });

    expect(response.status).toBe(200);
    const rotated = await response.json() as SessionResponse;
    expect(rotated.refreshToken).not.toBe(session.refreshToken);
    expect(rotated.accessToken).toBeTruthy();
  });

  /**
   * The theft-detection rule. A refresh token is single-use; a second presentation means
   * two parties hold it and there is no way to tell which is legitimate. Revoking the whole
   * chain forces a fresh sign-in — inconvenient, and far better than leaving a stranger
   * with a live session.
   */
  it('revokes every session when a used refresh token is presented again', async () => {
    const session = await newSession();
    const rotated = await (await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    })).json() as SessionResponse;

    const replay = await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    });
    expect(replay.status).toBe(401);

    // The token issued to the honest device is dead too — that is the point.
    const afterward = await post(null, '/v1/auth/refresh', {
      refreshToken: rotated.refreshToken,
    });
    expect(afterward.status).toBe(401);
  });

  it('refuses an unknown refresh token', async () => {
    const response = await post(null, '/v1/auth/refresh', { refreshToken: 'made-up' });
    expect(response.status).toBe(401);
  });

  it('refuses a refresh token after sign-out', async () => {
    const session = await newSession();
    expect((await post(null, '/v1/auth/signout', {
      refreshToken: session.refreshToken,
    })).status).toBe(204);

    const response = await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    });
    expect(response.status).toBe(401);
  });

  it('refuses to refresh a suspended account', async () => {
    const session = await newSession();
    await env.DB.prepare("update accounts set status = 'suspended'").run();

    const response = await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    });
    expect(response.status).toBe(401);
  });

  /** Refresh tokens are stored hashed, so a database dump cannot be replayed. */
  it('never stores the refresh token itself', async () => {
    const session = await newSession();
    const row = await env.DB.prepare('select token_hash from refresh_tokens')
      .first<{ token_hash: string }>();

    expect(row?.token_hash).not.toBe(session.refreshToken);
    expect(row?.token_hash).toHaveLength(64);
  });
});

describe('profile claiming', () => {
  async function account(): Promise<{ token: string }> {
    const session = await (await signIn()).json() as SessionResponse;
    return { token: session.accessToken };
  }

  function put(token: string, body: unknown): Promise<Response> {
    return api({ id: '', username: '', token }, '/v1/me/profile', {
      method: 'PUT',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
    });
  }

  it('claims a username and completes onboarding', async () => {
    const { token } = await account();
    const response = await put(token, { username: 'connor', displayName: 'Connor' });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ username: 'connor', displayName: 'Connor' });

    const me = await api({ id: '', username: '', token }, '/v1/me');
    expect(await me.json()).toMatchObject({ profile: { username: 'connor' } });
  });

  /** Case-folding stops "Connor" and "connor" from being two different people. */
  it('lowercases the username', async () => {
    const { token } = await account();
    const response = await put(token, { username: 'CoNnOr', displayName: 'Connor' });
    expect(await response.json()).toMatchObject({ username: 'connor' });
  });

  it('refuses a username already taken', async () => {
    const first = await account();
    await put(first.token, { username: 'connor', displayName: 'Connor' });

    apple.uninstall();
    apple = await createAppleFixture();
    apple.install();
    const second = await (await signIn({ sub: 'different.subject.0002' })).json() as SessionResponse;

    const response = await put(second.accessToken, {
      username: 'connor',
      displayName: 'Someone Else',
    });
    expect(response.status).toBe(409);
  });

  /** Impersonating support is the cheapest scam on a platform where people ask for help. */
  it.each(['admin', 'support', 'mymiracles', 'moderator', 'official'])(
    'refuses the reserved username %s',
    async (username) => {
      const { token } = await account();
      expect((await put(token, { username, displayName: 'X' })).status).toBe(409);
    },
  );

  it.each([
    ['too short', 'ab'],
    ['punctuation', 'con.nor'],
    ['spaces', 'con nor'],
    ['unicode lookalike', 'connоr'],
  ])('refuses an invalid username (%s)', async (_label, username) => {
    const { token } = await account();
    const response = await put(token, { username, displayName: 'X' });
    expect(response.status).toBe(422);
  });

  it('requires authentication', async () => {
    const response = await api(null, '/v1/me/profile', {
      method: 'PUT',
      body: JSON.stringify({ username: 'nobody', displayName: 'Nobody' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(response.status).toBe(401);
  });

  it('lets someone update their own profile later', async () => {
    const { token } = await account();
    await put(token, { username: 'connor', displayName: 'Connor' });

    const response = await put(token, {
      username: 'connor',
      displayName: 'Connor M',
      bio: 'Keeping track of the good.',
    });
    expect(await response.json()).toMatchObject({
      displayName: 'Connor M',
      bio: 'Keeping track of the good.',
    });
  });
});

describe('account deletion', () => {
  async function account(): Promise<SessionResponse> {
    return (await signIn()).json() as Promise<SessionResponse>;
  }

  it('schedules deletion and revokes every session immediately', async () => {
    const session = await account();
    const response = await api({ id: '', username: '', token: session.accessToken }, '/v1/me', {
      method: 'DELETE',
    });

    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({ alreadyRequested: false });

    // The decision takes effect now, even though erasure happens after the grace window.
    const refresh = await post(null, '/v1/auth/refresh', {
      refreshToken: session.refreshToken,
    });
    expect(refresh.status).toBe(401);
  });

  it('is idempotent', async () => {
    const session = await account();
    const viewer = { id: '', username: '', token: session.accessToken };

    await api(viewer, '/v1/me', { method: 'DELETE' });
    const second = await api(viewer, '/v1/me', { method: 'DELETE' });

    expect(await second.json()).toMatchObject({ alreadyRequested: true });

    const rows = await env.DB.prepare('select count(*) as n from deletion_requests')
      .first<{ n: number }>();
    expect(rows?.n).toBe(1);
  });

  it('can be cancelled inside the grace window', async () => {
    const session = await account();
    const viewer = { id: '', username: '', token: session.accessToken };

    await api(viewer, '/v1/me', { method: 'DELETE' });
    expect((await post(viewer, '/v1/me/cancel-deletion', {})).status).toBe(204);

    const row = await env.DB.prepare('select state from deletion_requests')
      .first<{ state: string }>();
    expect(row?.state).toBe('cancelled');
  });

  it('requires authentication', async () => {
    expect((await api(null, '/v1/me', { method: 'DELETE' })).status).toBe(401);
  });
});
