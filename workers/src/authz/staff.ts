import type { Env } from '../env';
import { requireViewer, type Viewer } from '../auth/context';
import { sha256Hex } from '../auth/tokens';
import { hidden, unauthenticated } from '../http/responses';
import { now } from '../db/ids';

/** Service tokens are prefixed so they are recognisable in a log or a leak scan. */
const STAFF_TOKEN_PREFIX = 'mm_staff_';

/**
 * Moderator access.
 *
 * Being staff is a separate grant in its own table, never a property of an account that
 * could accumulate. Every moderation route calls {@link requireStaff} before anything else.
 *
 * A non-staff caller gets **404, not 403**. A 403 would confirm that a moderation surface
 * exists at that path and that this is a real case id — useful reconnaissance for someone
 * probing for the tooling that governs them.
 */
export interface Moderator extends Viewer {
  role: 'moderator' | 'admin';
}

export async function requireStaff(request: Request, env: Env): Promise<Moderator> {
  const header = request.headers.get('Authorization') ?? '';

  // The moderation console runs server-side and presents a service token, which outlives a
  // 15-minute access token. It opens nothing but these routes.
  if (header.startsWith(`Bearer ${STAFF_TOKEN_PREFIX}`)) {
    return staffFromServiceToken(env, header.slice(7).trim());
  }

  // A valid session first: staff are ordinary accounts with an extra grant, so suspension,
  // expiry and token rotation all apply to them exactly as they do to everyone else.
  const viewer = await requireViewer(request, env);

  const row = await env.DB.prepare('select role from staff where account_id = ?')
    .bind(viewer.accountId)
    .first<{ role: 'moderator' | 'admin' }>();

  if (!row) throw hidden();

  return { accountId: viewer.accountId, role: row.role };
}

/**
 * Resolves a service token to the staff account it belongs to.
 *
 * The token is stored only as a hash, so a database dump cannot be replayed. Attribution
 * survives: the audit trail records the named account, not "the console".
 */
async function staffFromServiceToken(env: Env, token: string): Promise<Moderator> {
  const record = await env.DB.prepare(`
    select t.id, t.account_id, t.expires_at, t.revoked_at, s.role, a.status
    from staff_tokens t
    join staff s on s.account_id = t.account_id
    join accounts a on a.id = t.account_id
    where t.token_hash = ?
  `)
    .bind(await sha256Hex(token))
    .first<{
      id: string; account_id: string; expires_at: number | null;
      revoked_at: number | null; role: 'moderator' | 'admin'; status: string;
    }>();

  // An unknown, revoked or expired token is 401 — the caller supplied a credential and it
  // is bad, which is worth saying plainly. A *valid* session lacking the staff grant still
  // gets 404, because that answer must not confirm the surface exists.
  if (!record || record.revoked_at !== null) throw unauthenticated('invalid staff token');
  if (record.expires_at !== null && record.expires_at <= now()) {
    throw unauthenticated('staff token has expired');
  }
  if (record.status !== 'active') throw unauthenticated('account is not active');

  await env.DB.prepare('update staff_tokens set last_used_at = ? where id = ?')
    .bind(now(), record.id)
    .run();

  return { accountId: record.account_id, role: record.role };
}

/** Some actions — granting staff, reinstating a suspension — are admin-only. */
export async function requireAdmin(request: Request, env: Env): Promise<Moderator> {
  const moderator = await requireStaff(request, env);
  if (moderator.role !== 'admin') throw hidden();
  return moderator;
}
