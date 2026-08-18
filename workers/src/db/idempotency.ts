import type { Env } from '../env';
import type { Viewer } from '../auth/context';
import { forbidden } from '../http/responses';
import { now } from './ids';

/**
 * Idempotency for mutating requests.
 *
 * Someone may write something heartfelt on a bad connection and the phone may retry. A
 * retry must replay the original result, not create a second prayer.
 *
 * Keys are global (the table's primary key) but bound to an account. Presenting a key
 * that belongs to somebody else is refused rather than replayed — otherwise guessing a
 * key would return another person's record.
 */
export async function replayResult(
  env: Env,
  viewer: Viewer,
  key: string | null,
  operation: string,
): Promise<string | null> {
  if (!key) return null;

  const existing = await env.DB.prepare(
    'select account_id, operation, result_ref from mutation_keys where key = ?',
  )
    .bind(key)
    .first<{ account_id: string; operation: string; result_ref: string | null }>();

  if (!existing) return null;
  if (existing.account_id !== viewer.accountId) {
    throw forbidden('idempotency key belongs to another account');
  }
  if (existing.operation !== operation) {
    throw forbidden('idempotency key was used for a different operation');
  }
  return existing.result_ref;
}

export function recordKeyStatement(
  env: Env,
  viewer: Viewer,
  key: string | null,
  operation: string,
  resultRef: string,
): D1PreparedStatement[] {
  if (!key) return [];
  return [
    env.DB.prepare(
      'insert into mutation_keys (key, account_id, operation, result_ref, created_at) values (?, ?, ?, ?, ?)',
    ).bind(key, viewer.accountId, operation, resultRef, now()),
  ];
}

export function idempotencyKey(request: Request): string | null {
  const key = request.headers.get('Idempotency-Key');
  return key && key.length > 0 && key.length <= 200 ? key : null;
}
