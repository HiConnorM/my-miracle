import { env, SELF } from 'cloudflare:test';
import { signAccessToken } from '../src/auth/tokens';
import { uuidv7 } from '../src/db/ids';
import type { PostType, PostVisibility } from '../src/db/types';

/**
 * Fixtures are written straight to D1 rather than through the API, because the signup and
 * session routes arrive in Phase 3. Tokens are minted with the real signing function, so
 * these tests exercise the same authentication path production will.
 */
export interface TestAccount {
  id: string;
  username: string;
  token: string;
}

/**
 * Child tables first, so foreign keys never block a delete.
 *
 * Every test starts from an empty database. Without this a test could pass because of
 * rows another test happened to leave behind — and in an authorization suite, a test that
 * passes for the wrong reason is worse than no test.
 */
const TABLES_CHILDREN_FIRST = [
  'event_outbox',
  'deletion_requests',
  'mutation_keys',
  'user_entitlements',
  'notification_events',
  'moderation_actions',
  'reports',
  'moderation_cases',
  'blocks',
  'follows',
  'comments',
  'answered_links',
  'prayer_responses',
  'post_updates',
  'post_media',
  'post_authorship',
  'posts',
  'refresh_tokens',
  'devices',
  'auth_identities',
  'profiles',
  'accounts',
] as const;

export async function resetDatabase(): Promise<void> {
  await env.DB.batch(
    TABLES_CHILDREN_FIRST.map((table) => env.DB.prepare(`delete from ${table}`)),
  );
}

export async function createAccount(username: string): Promise<TestAccount> {
  const id = uuidv7();
  const timestamp = Date.now();

  await env.DB.batch([
    env.DB.prepare(
      'insert into accounts (id, status, created_at, updated_at) values (?, ?, ?, ?)',
    ).bind(id, 'active', timestamp, timestamp),
    env.DB.prepare(
      `insert into profiles (account_id, username, display_name, created_at, updated_at)
       values (?, ?, ?, ?, ?)`,
    ).bind(id, username, username, timestamp, timestamp),
  ]);

  return {
    id,
    username,
    token: await signAccessToken(env.SESSION_SIGNING_KEY, id),
  };
}

export async function suspend(account: TestAccount): Promise<void> {
  await env.DB.prepare('update accounts set status = ? where id = ?')
    .bind('suspended', account.id)
    .run();
}

export interface PostOptions {
  type?: PostType;
  body?: string;
  visibility?: PostVisibility;
  anonymous?: boolean;
  status?: 'active' | 'answered' | 'archived' | 'removed';
}

export async function createPost(
  owner: TestAccount,
  options: PostOptions = {},
): Promise<string> {
  const {
    type = 'prayer',
    body = 'Please pray for my marriage.',
    visibility = 'public',
    anonymous = false,
    status = 'active',
  } = options;

  const id = uuidv7();
  const timestamp = Date.now();
  const displayProfileId = anonymous ? null : owner.id;

  await env.DB.batch([
    env.DB.prepare(
      `insert into posts (id, type, body, visibility, status, display_profile_id, created_at, updated_at, answered_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      id,
      type,
      body,
      visibility,
      status,
      displayProfileId,
      timestamp,
      timestamp,
      status === 'answered' ? timestamp : null,
    ),
    env.DB.prepare(
      'insert into post_authorship (post_id, owner_id, created_at) values (?, ?, ?)',
    ).bind(id, owner.id, timestamp),
  ]);

  return id;
}

export async function follow(follower: TestAccount, followee: TestAccount): Promise<void> {
  const timestamp = Date.now();
  await env.DB.prepare(
    `insert into follows (follower_id, followee_id, state, created_at, updated_at)
     values (?, ?, 'accepted', ?, ?)`,
  )
    .bind(follower.id, followee.id, timestamp, timestamp)
    .run();
}

export async function block(blocker: TestAccount, blocked: TestAccount): Promise<void> {
  await env.DB.prepare(
    'insert into blocks (blocker_id, blocked_id, created_at) values (?, ?, ?)',
  )
    .bind(blocker.id, blocked.id, Date.now())
    .run();
}

/** A request as an authenticated account, dispatched through the real Worker. */
export function api(
  account: TestAccount | null,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const headers = new Headers(init.headers);
  if (account) headers.set('Authorization', `Bearer ${account.token}`);
  if (init.body) headers.set('Content-Type', 'application/json');

  return SELF.fetch(`https://api.test${path}`, { ...init, headers });
}

export function post(
  account: TestAccount | null,
  path: string,
  body: unknown,
  init: RequestInit = {},
): Promise<Response> {
  return api(account, path, { ...init, method: 'POST', body: JSON.stringify(body) });
}

export function patch(
  account: TestAccount | null,
  path: string,
  body: unknown,
): Promise<Response> {
  return api(account, path, { method: 'PATCH', body: JSON.stringify(body) });
}

export function del(account: TestAccount | null, path: string): Promise<Response> {
  return api(account, path, { method: 'DELETE' });
}
