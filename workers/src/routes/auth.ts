import type { RouteContext } from '../http/router';
import { requireViewer } from '../auth/context';
import { conflict, invalid, json, noContent } from '../http/responses';
import { optionalString, readJson, requireString } from '../http/body';
import { verifyAppleIdentityToken } from '../auth/apple';
import { createSession, revokeAllSessions, revokeSession, rotateSession } from '../auth/sessions';
import { now, uuidv7 } from '../db/ids';

/**
 * Sign in with Apple.
 *
 * The client sends the identity token it received from `ASAuthorizationAppleIDProvider`.
 * Nothing about the caller is trusted until Apple's signature over that token verifies —
 * in particular the account is resolved from Apple's `sub`, never from anything the client
 * says about itself.
 *
 * On first sign-in this creates an account but **not** a profile. A person picks their
 * username during onboarding, and until they do, `profile` is null and the app knows to
 * ask. Separating the two is what lets someone abandon onboarding without leaving a
 * half-built identity behind.
 */
export async function signInWithApple({ request, env }: RouteContext): Promise<Response> {
  const body = await readJson(request);
  const identityToken = requireString(body, 'identityToken', { max: 4000 });
  const nonce = optionalString(body, 'nonce', { max: 200 });

  const identity = await verifyAppleIdentityToken(identityToken, {
    clientId: env.MM_APPLE_CLIENT_ID,
    nonce,
  });

  const existing = await env.DB.prepare(
    `select account_id from auth_identities where provider = 'apple' and provider_subject = ?`,
  )
    .bind(identity.subject)
    .first<{ account_id: string }>();

  const timestamp = now();
  let accountId: string;
  let isNewAccount = false;

  if (existing) {
    accountId = existing.account_id;

    const account = await env.DB.prepare('select status from accounts where id = ?')
      .bind(accountId)
      .first<{ status: string }>();
    if (!account || account.status !== 'active') {
      // A suspended account cannot sign back in to escape the suspension.
      throw invalid('this account is not available');
    }

    await env.DB.prepare(
      `update auth_identities set last_used_at = ?, email = coalesce(?, email)
       where provider = 'apple' and provider_subject = ?`,
    )
      .bind(timestamp, identity.email, identity.subject)
      .run();
  } else {
    accountId = uuidv7();
    isNewAccount = true;

    await env.DB.batch([
      env.DB.prepare(
        'insert into accounts (id, status, created_at, updated_at) values (?, ?, ?, ?)',
      ).bind(accountId, 'active', timestamp, timestamp),
      env.DB.prepare(
        `insert into auth_identities
           (id, account_id, provider, provider_subject, email, email_is_private_relay, created_at, last_used_at)
         values (?, ?, 'apple', ?, ?, ?, ?, ?)`,
      ).bind(
        uuidv7(),
        accountId,
        identity.subject,
        identity.email,
        identity.emailIsPrivateRelay ? 1 : 0,
        timestamp,
        timestamp,
      ),
      env.DB.prepare(
        `insert into user_entitlements (account_id, entitlement, status, updated_at)
         values (?, 'free', 'active', ?)`,
      ).bind(accountId, timestamp),
    ]);
  }

  const session = await createSession(env, accountId);
  const profile = await loadProfile(env, accountId);

  return json({ ...session, isNewAccount, profile }, isNewAccount ? 201 : 200);
}

export async function refreshSession({ request, env }: RouteContext): Promise<Response> {
  const body = await readJson(request);
  const refreshToken = requireString(body, 'refreshToken', { max: 500 });
  return json(await rotateSession(env, refreshToken));
}

export async function signOut({ request, env }: RouteContext): Promise<Response> {
  const body = await readJson(request);
  const refreshToken = requireString(body, 'refreshToken', { max: 500 });
  await revokeSession(env, refreshToken);
  return noContent();
}

export async function getMe({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  return json({
    accountId: viewer.accountId,
    profile: await loadProfile(env, viewer.accountId),
  });
}

/**
 * Usernames that must not be claimable.
 *
 * Impersonating support or the product itself is the cheapest scam available on a platform
 * where people are asking strangers for help, so these are reserved before anyone thinks to
 * ask for them.
 */
const RESERVED_USERNAMES = new Set([
  'admin', 'administrator', 'support', 'help', 'moderator', 'mod', 'staff', 'team',
  'official', 'mymiracles', 'my_miracles', 'miracles', 'miracle', 'root', 'system',
  'security', 'billing', 'legal', 'privacy', 'about', 'settings', 'me', 'you', 'null',
  'undefined', 'anonymous', 'anon', 'deleted',
]);

/**
 * Claims or updates a profile. This is the last step of onboarding.
 *
 * Usernames are lowercase to make impersonation by case ("Connor" vs "connor") impossible.
 */
export async function putProfile({ request, env }: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const body = await readJson(request);

  const username = requireString(body, 'username', { min: 3, max: 24 }).toLowerCase();
  const displayName = requireString(body, 'displayName', { min: 1, max: 60 });
  const bio = optionalString(body, 'bio', { max: 300 });

  if (!/^[a-z0-9_]+$/.test(username)) {
    throw invalid('a username can use only letters, numbers and underscores');
  }
  if (RESERVED_USERNAMES.has(username)) {
    throw conflict('that username is not available');
  }

  const taken = await env.DB.prepare(
    'select account_id from profiles where username = ? and account_id <> ?',
  )
    .bind(username, viewer.accountId)
    .first<{ account_id: string }>();
  if (taken) throw conflict('that username is already taken');

  const timestamp = now();
  await env.DB.prepare(
    `insert into profiles (account_id, username, display_name, bio, created_at, updated_at)
     values (?1, ?2, ?3, ?4, ?5, ?5)
     on conflict (account_id) do update
       set username = ?2, display_name = ?3, bio = ?4, updated_at = ?5`,
  )
    .bind(viewer.accountId, username, displayName, bio ?? null, timestamp)
    .run();

  return json(await loadProfile(env, viewer.accountId));
}

/**
 * Starts account deletion. Apple requires this to be reachable from inside the app.
 *
 * Scheduled rather than immediate: a seven-day window makes an accidental tap recoverable.
 * All sessions are revoked straight away, so the decision takes effect even though the data
 * has not been erased yet. The job that performs the erasure lands in Phase 9 alongside the
 * rest of the moderation and retention tooling.
 */
export async function requestAccountDeletion({
  request,
  env,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);
  const timestamp = now();
  const scheduledFor = timestamp + 7 * 24 * 60 * 60 * 1000;

  const pending = await env.DB.prepare(
    `select scheduled_for from deletion_requests
     where account_id = ? and state in ('scheduled', 'processing')`,
  )
    .bind(viewer.accountId)
    .first<{ scheduled_for: number }>();

  if (pending) {
    return json({ scheduledFor: pending.scheduled_for, alreadyRequested: true });
  }

  await env.DB.batch([
    env.DB.prepare(
      `insert into deletion_requests (id, account_id, state, requested_at, scheduled_for)
       values (?, ?, 'scheduled', ?, ?)`,
    ).bind(uuidv7(), viewer.accountId, timestamp, scheduledFor),
    env.DB.prepare(
      'update refresh_tokens set revoked_at = ? where account_id = ? and revoked_at is null',
    ).bind(timestamp, viewer.accountId),
  ]);

  return json({ scheduledFor, alreadyRequested: false }, 202);
}

export async function cancelAccountDeletion({
  request,
  env,
}: RouteContext): Promise<Response> {
  const viewer = await requireViewer(request, env);

  await env.DB.prepare(
    `update deletion_requests set state = 'cancelled'
     where account_id = ? and state = 'scheduled'`,
  )
    .bind(viewer.accountId)
    .run();

  return noContent();
}

interface ProfileView {
  username: string;
  displayName: string;
  avatarKey: string | null;
  bio: string | null;
}

async function loadProfile(
  env: RouteContext['env'],
  accountId: string,
): Promise<ProfileView | null> {
  const row = await env.DB.prepare(
    'select username, display_name, avatar_key, bio from profiles where account_id = ?',
  )
    .bind(accountId)
    .first<{
      username: string;
      display_name: string;
      avatar_key: string | null;
      bio: string | null;
    }>();

  return row
    ? {
        username: row.username,
        displayName: row.display_name,
        avatarKey: row.avatar_key,
        bio: row.bio,
      }
    : null;
}

// `revokeAllSessions` is used by the rotation theft-detection path in sessions.ts.
export { revokeAllSessions };
