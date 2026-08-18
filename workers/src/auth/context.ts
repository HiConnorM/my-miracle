import type { Env } from '../env';
import { unauthenticated } from '../http/responses';
import { verifyAccessToken } from './tokens';

/**
 * Who is asking.
 *
 * Resolved **only** from the `Authorization` header. Never from a request body, a query
 * parameter or a path segment — those are attacker-controlled, and an app with no RLS
 * cannot afford a second, weaker way to say who you are.
 */
export interface Viewer {
  accountId: string;
}

/**
 * Requires a signed-in caller.
 *
 * Also confirms the account still exists and is active, so a suspended or deleted account
 * cannot keep acting on a token that has not expired yet.
 */
export async function requireViewer(request: Request, env: Env): Promise<Viewer> {
  const header = request.headers.get('Authorization');
  if (!header?.startsWith('Bearer ')) {
    throw unauthenticated('missing bearer token');
  }

  const claims = await verifyAccessToken(env.SESSION_SIGNING_KEY, header.slice(7).trim());
  if (!claims) {
    throw unauthenticated('invalid or expired token');
  }

  const account = await env.DB.prepare('select status from accounts where id = ?')
    .bind(claims.sub)
    .first<{ status: string }>();

  if (!account || account.status !== 'active') {
    throw unauthenticated('account is not active');
  }

  return { accountId: claims.sub };
}
