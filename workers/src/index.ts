/**
 * My Miracles API.
 *
 * Cloudflare D1 has no row-level security, so this Worker is the ONLY thing that reads or
 * writes the database. The iOS client holds no database credential and cannot issue a
 * query — every request passes through here, where authorization is decided once, in
 * typed code, against the matrix in docs/database.md.
 *
 * That is a real chokepoint rather than a convention, but it also means a missing check
 * has no second line of defence. Every route below resolves a viewer and then asks
 * `src/authz/policy.ts` — routes never re-derive an authorization decision themselves.
 */

import type { Env } from './env';
import { Router } from './http/router';
import { json } from './http/responses';
import { createPost, deletePost, getFeed, getPost, updatePost } from './routes/posts';
import { exportJournal, getJournal, getJournalSummary } from './routes/journal';
import {
  createComment,
  createPrayerResponse,
  deleteComment,
  deletePrayerResponse,
  listComments,
} from './routes/interactions';
import {
  createBlock,
  deleteBlock,
  followProfile,
  getProfile,
  getProfileTimeline,
  unfollowProfile,
} from './routes/social';
import { createReport } from './routes/reports';
import { listSaved, savePost, searchPeople, unsavePost } from './routes/discovery';
import { answerPrayer, createPostUpdate, listPostUpdates } from './routes/answering';
import { getHome } from './routes/home';
import {
  cancelAccountDeletion,
  getMe,
  putProfile,
  refreshSession,
  requestAccountDeletion,
  signInWithApple,
  signOut,
} from './routes/auth';

export type { Env };

const router = new Router()
  .get('/health', ({ env }) => health(env))

  // Sessions. Only these three routes are reachable without a bearer token.
  .post('/v1/auth/apple', signInWithApple)
  .post('/v1/auth/refresh', refreshSession)
  .post('/v1/auth/signout', signOut)

  // Account
  .get('/v1/me', getMe)
  .put('/v1/me/profile', putProfile)
  .delete('/v1/me', requestAccountDeletion)
  .post('/v1/me/cancel-deletion', cancelAccountDeletion)

  // Content
  .get('/v1/home', getHome)
  .get('/v1/feed', getFeed)
  .get('/v1/me/journal', getJournal)
  .get('/v1/me/journal/summary', getJournalSummary)
  .get('/v1/me/export', exportJournal)
  .post('/v1/posts', createPost)
  .get('/v1/posts/:id', getPost)
  .patch('/v1/posts/:id', updatePost)
  .delete('/v1/posts/:id', deletePost)

  // Interactions
  .post('/v1/posts/:id/prayers', createPrayerResponse)
  .delete('/v1/posts/:id/prayers', deletePrayerResponse)
  .get('/v1/posts/:id/comments', listComments)
  .post('/v1/posts/:id/comments', createComment)
  .get('/v1/posts/:id/updates', listPostUpdates)
  .post('/v1/posts/:id/updates', createPostUpdate)

  // The core loop. One transactional route, owner only.
  .post('/v1/posts/:id/answer', answerPrayer)
  .delete('/v1/comments/:id', deleteComment)

  // People
  .get('/v1/profiles/:username', getProfile)
  .get('/v1/profiles/:username/posts', getProfileTimeline)
  .post('/v1/follows', followProfile)
  .delete('/v1/follows/:username', unfollowProfile)
  .post('/v1/blocks', createBlock)
  .delete('/v1/blocks/:username', deleteBlock)

  // Saving and finding people. Discovery is a search box, not a ranked feed.
  .post('/v1/posts/:id/save', savePost)
  .delete('/v1/posts/:id/save', unsavePost)
  .get('/v1/me/saved', listSaved)
  .get('/v1/people', searchPeople)

  // Safety
  .post('/v1/reports', createReport);

// Deliberately absent, and not an oversight: there is no client route to
// `moderation_cases`, `moderation_actions`, `post_authorship`, `refresh_tokens` or
// `user_entitlements`. Tables with no route cannot be reached at all, which is a stronger
// guarantee than a policy that refuses them. Staff tooling reaches moderation through the
// admin surface added in Phase 9, behind a separate credential.

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return router.handle(request, env);
  },
} satisfies ExportedHandler<Env>;

/**
 * Confirms the Worker is running and its D1 binding resolves. Deliberately reports schema
 * shape only — never a count of user content, which would leak activity levels to anyone
 * who can reach the endpoint.
 */
async function health(env: Env): Promise<Response> {
  try {
    const result = await env.DB.prepare(
      "select count(*) as tables from sqlite_master where type = 'table' and name not like 'sqlite_%'",
    ).first<{ tables: number }>();

    return json({
      status: 'ok',
      environment: env.MM_ENVIRONMENT,
      database: { reachable: true, tables: result?.tables ?? 0 },
    });
  } catch (error) {
    return json(
      {
        status: 'degraded',
        environment: env.MM_ENVIRONMENT,
        database: { reachable: false },
        detail: error instanceof Error ? error.message : 'unknown',
      },
      503,
    );
  }
}
