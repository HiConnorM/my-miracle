import { describe, it, expect } from 'vitest';
import {
  ACCESS_TOKEN_TTL_SECONDS,
  sha256Hex,
  signAccessToken,
  verifyAccessToken,
} from '../src/auth/tokens';

const KEY = 'test-signing-key';

describe('access tokens', () => {
  it('round-trips the account id', async () => {
    const token = await signAccessToken(KEY, 'account-1');
    const claims = await verifyAccessToken(KEY, token);

    expect(claims?.sub).toBe('account-1');
    expect(claims!.exp - claims!.iat).toBe(ACCESS_TOKEN_TTL_SECONDS);
  });

  /**
   * The attack this defends against: take your own valid token, swap the `sub` for
   * somebody else's account id, and re-send it. Without signature verification over the
   * payload that is a complete authentication bypass.
   */
  it('rejects a token whose payload has been swapped for another account', async () => {
    const token = await signAccessToken(KEY, 'account-1');
    const [header, , signature] = token.split('.') as [string, string, string];

    const forgedPayload = btoa(
      JSON.stringify({ sub: 'account-2', iat: 0, exp: 9_999_999_999 }),
    )
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

    expect(await verifyAccessToken(KEY, `${header}.${forgedPayload}.${signature}`)).toBeNull();
  });

  it('rejects a token signed with a different key', async () => {
    const token = await signAccessToken('another-key', 'account-1');
    expect(await verifyAccessToken(KEY, token)).toBeNull();
  });

  it('rejects an expired token', async () => {
    const token = await signAccessToken(KEY, 'account-1', Date.now() - 60 * 60 * 1000);
    expect(await verifyAccessToken(KEY, token)).toBeNull();
  });

  it('accepts a token right up to its expiry', async () => {
    const issuedAt = Date.now();
    const token = await signAccessToken(KEY, 'account-1', issuedAt);
    const justBefore = issuedAt + ACCESS_TOKEN_TTL_SECONDS * 1000 - 1000;

    expect(await verifyAccessToken(KEY, token, justBefore)).not.toBeNull();
  });

  it.each([
    ['empty', ''],
    ['not a JWT', 'nonsense'],
    ['two segments', 'a.b'],
    ['four segments', 'a.b.c.d'],
    ['unparseable payload', 'aaa.!!!!.ccc'],
  ])('rejects a malformed token (%s)', async (_label, token) => {
    expect(await verifyAccessToken(KEY, token)).toBeNull();
  });

  it('rejects a token carrying no subject', async () => {
    const header = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const payload = btoa(JSON.stringify({ exp: 9_999_999_999 }));
    expect(await verifyAccessToken(KEY, `${header}.${payload}.sig`)).toBeNull();
  });
});

describe('refresh token hashing', () => {
  /**
   * Refresh tokens are stored only as a hash, so a database dump cannot be replayed to
   * impersonate anyone.
   */
  it('is deterministic and does not reveal the input', async () => {
    const hash = await sha256Hex('a-refresh-token');

    expect(hash).toBe(await sha256Hex('a-refresh-token'));
    expect(hash).toHaveLength(64);
    expect(hash).not.toContain('a-refresh-token');
    expect(hash).not.toBe(await sha256Hex('a-refresh-tokem'));
  });
});
