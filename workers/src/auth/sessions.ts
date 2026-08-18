import type { Env } from '../env';
import { unauthenticated } from '../http/responses';
import { now, uuidv7 } from '../db/ids';
import { ACCESS_TOKEN_TTL_SECONDS, sha256Hex, signAccessToken } from './tokens';

/**
 * Session lifecycle: a short-lived access token plus a long-lived, single-use refresh
 * token.
 *
 * The refresh token is opaque and only its SHA-256 hash is stored, so a database dump
 * cannot be replayed to impersonate anyone. Each use rotates it, and presenting an
 * already-rotated token means a copy is loose — see {@link rotateSession}.
 */

const REFRESH_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000; // 60 days

export interface SessionPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export async function createSession(
  env: Env,
  accountId: string,
  deviceId: string | null = null,
): Promise<SessionPair> {
  const refreshToken = generateRefreshToken();
  const timestamp = now();

  await env.DB.prepare(
    `insert into refresh_tokens (id, account_id, token_hash, device_id, issued_at, expires_at)
     values (?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      uuidv7(),
      accountId,
      await sha256Hex(refreshToken),
      deviceId,
      timestamp,
      timestamp + REFRESH_TOKEN_TTL_MS,
    )
    .run();

  return {
    accessToken: await signAccessToken(env.SESSION_SIGNING_KEY, accountId),
    refreshToken,
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
  };
}

/**
 * Exchanges a refresh token for a new pair, rotating it.
 *
 * **Theft detection.** A refresh token is single-use. If one is presented after it has
 * already been rotated, two parties hold it — the legitimate device and somebody else — and
 * there is no way to tell which is which. The safe response is to revoke the entire chain
 * and make everyone sign in again. An inconvenient sign-in is a much better outcome than a
 * silent, persistent session on a stranger's device.
 */
export async function rotateSession(env: Env, refreshToken: string): Promise<SessionPair> {
  const hash = await sha256Hex(refreshToken);

  const record = await env.DB.prepare(
    `select id, account_id, expires_at, revoked_at, replaced_by, device_id
     from refresh_tokens where token_hash = ?`,
  )
    .bind(hash)
    .first<{
      id: string;
      account_id: string;
      expires_at: number;
      revoked_at: number | null;
      replaced_by: string | null;
      device_id: string | null;
    }>();

  if (!record) throw unauthenticated('unknown refresh token');

  if (record.replaced_by !== null || record.revoked_at !== null) {
    await revokeAllSessions(env, record.account_id);
    throw unauthenticated('refresh token was already used; all sessions revoked');
  }

  if (record.expires_at <= now()) {
    throw unauthenticated('refresh token has expired');
  }

  const account = await env.DB.prepare('select status from accounts where id = ?')
    .bind(record.account_id)
    .first<{ status: string }>();
  if (!account || account.status !== 'active') {
    throw unauthenticated('account is not active');
  }

  const nextToken = generateRefreshToken();
  const nextId = uuidv7();
  const timestamp = now();

  await env.DB.batch([
    env.DB.prepare(
      `insert into refresh_tokens (id, account_id, token_hash, device_id, issued_at, expires_at)
       values (?, ?, ?, ?, ?, ?)`,
    ).bind(
      nextId,
      record.account_id,
      await sha256Hex(nextToken),
      record.device_id,
      timestamp,
      timestamp + REFRESH_TOKEN_TTL_MS,
    ),
    // Marking the old token replaced is what makes a second presentation detectable.
    env.DB.prepare(
      'update refresh_tokens set replaced_by = ?, revoked_at = ? where id = ?',
    ).bind(nextId, timestamp, record.id),
  ]);

  return {
    accessToken: await signAccessToken(env.SESSION_SIGNING_KEY, record.account_id),
    refreshToken: nextToken,
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
  };
}

/** Signs out one device. Unknown tokens succeed silently — sign-out should never fail. */
export async function revokeSession(env: Env, refreshToken: string): Promise<void> {
  await env.DB.prepare(
    'update refresh_tokens set revoked_at = ? where token_hash = ? and revoked_at is null',
  )
    .bind(now(), await sha256Hex(refreshToken))
    .run();
}

export async function revokeAllSessions(env: Env, accountId: string): Promise<void> {
  await env.DB.prepare(
    'update refresh_tokens set revoked_at = ? where account_id = ? and revoked_at is null',
  )
    .bind(now(), accountId)
    .run();
}

/**
 * 256 bits from the CSPRNG. The token carries no structure — it is a lookup key for a
 * hashed row, not something to be parsed or trusted on its own.
 */
function generateRefreshToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
