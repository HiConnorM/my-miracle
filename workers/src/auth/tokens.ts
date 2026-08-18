/**
 * Session access tokens: HS256 JWTs signed with a Worker secret.
 *
 * The access token is short-lived and verified without a database round trip. Refresh
 * tokens are a different thing entirely — opaque, stored only as a SHA-256 hash in
 * `refresh_tokens`, and rotated on use. Phase 3 adds refresh rotation and Apple identity
 * token verification on top of this.
 */

export interface AccessTokenClaims {
  /** Account id. */
  sub: string;
  /** Issued at, epoch seconds. */
  iat: number;
  /** Expires at, epoch seconds. */
  exp: number;
}

export const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;

export async function signAccessToken(
  signingKey: string,
  accountId: string,
  nowMs = Date.now(),
): Promise<string> {
  const issuedAt = Math.floor(nowMs / 1000);
  const claims: AccessTokenClaims = {
    sub: accountId,
    iat: issuedAt,
    exp: issuedAt + ACCESS_TOKEN_TTL_SECONDS,
  };

  const header = encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = encode(JSON.stringify(claims));
  const signature = await hmac(signingKey, `${header}.${payload}`);

  return `${header}.${payload}.${signature}`;
}

/**
 * Returns the claims, or `null` for anything that is not a valid, unexpired token signed
 * with our key. Callers must treat `null` as "no session" — never as "trust the payload
 * anyway".
 */
export async function verifyAccessToken(
  signingKey: string,
  token: string,
  nowMs = Date.now(),
): Promise<AccessTokenClaims | null> {
  const parts = token.split('.');
  if (parts.length !== 3) return null;

  const [header, payload, signature] = parts as [string, string, string];

  const expected = await hmac(signingKey, `${header}.${payload}`);
  // Constant-time comparison: a leaky compare lets an attacker discover a valid signature
  // byte by byte.
  if (!timingSafeEqual(signature, expected)) return null;

  let claims: AccessTokenClaims;
  try {
    claims = JSON.parse(decode(payload)) as AccessTokenClaims;
  } catch {
    return null;
  }

  if (typeof claims.sub !== 'string' || claims.sub.length === 0) return null;
  if (typeof claims.exp !== 'number') return null;
  if (claims.exp * 1000 <= nowMs) return null;

  return claims;
}

async function hmac(signingKey: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(signingKey),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return base64url(new Uint8Array(signature));
}

/** SHA-256, hex. Used for refresh tokens, which are never stored in the clear. */
export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

function encode(value: string): string {
  return base64url(new TextEncoder().encode(value));
}

function decode(value: string): string {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), '='));
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function base64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
