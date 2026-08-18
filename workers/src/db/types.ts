export type PostType = 'prayer' | 'miracle' | 'gratitude' | 'testimony';
export type PostVisibility = 'private' | 'followers' | 'public';
export type PostStatus = 'active' | 'answered' | 'archived' | 'removed';

export const POST_TYPES: readonly PostType[] = ['prayer', 'miracle', 'gratitude', 'testimony'];
export const POST_VISIBILITIES: readonly PostVisibility[] = ['private', 'followers', 'public'];

/**
 * A post as loaded from the database, **including `ownerId`**.
 *
 * `ownerId` comes from `post_authorship` and is required to authorize anything — for an
 * anonymous post it is the only link to the author. It must never leave the Worker.
 * Responses are built by {@link serializePost}, which constructs a fresh object from an
 * explicit field list rather than spreading this one.
 *
 * If you find yourself writing `{ ...post }` into a response, stop: that is precisely the
 * bug that would expose who asked for prayer about their marriage.
 */
export interface PostRecord {
  id: string;
  type: PostType;
  body: string;
  visibility: PostVisibility;
  status: PostStatus;
  displayProfileId: string | null;
  ownerId: string;
  createdAt: number;
  updatedAt: number;
  answeredAt: number | null;
  version: number;
  prayerResponseCount: number;
  commentCount: number;
  updateCount: number;
  displayUsername: string | null;
  displayName: string | null;
  displayAvatarKey: string | null;
}

/** The author as shown to readers. `null` means the post is anonymous. */
export interface DisplayProfileView {
  username: string;
  displayName: string;
  avatarKey: string | null;
}

/** Exactly what a client receives. Note the absence of any owner field. */
export interface PostView {
  id: string;
  type: PostType;
  body: string;
  visibility: PostVisibility;
  status: PostStatus;
  createdAt: number;
  updatedAt: number;
  answeredAt: number | null;
  version: number;
  prayerResponseCount: number;
  commentCount: number;
  updateCount: number;
  displayProfile: DisplayProfileView | null;
  /** Whether the viewer owns this post — true for one's own anonymous posts. */
  isMine: boolean;
  /** Whether the viewer has already prayed. Drives the "I prayed" button state. */
  hasPrayed: boolean;
}

/**
 * The only sanctioned way to turn a record into a response.
 *
 * Every field is named explicitly. `ownerId` is not among them, and adding it would be a
 * deliberate act rather than an accident of spreading an object.
 */
export function serializePost(
  post: PostRecord,
  options: { viewerAccountId: string; hasPrayed: boolean },
): PostView {
  return {
    id: post.id,
    type: post.type,
    body: post.body,
    visibility: post.visibility,
    status: post.status,
    createdAt: post.createdAt,
    updatedAt: post.updatedAt,
    answeredAt: post.answeredAt,
    version: post.version,
    prayerResponseCount: post.prayerResponseCount,
    commentCount: post.commentCount,
    updateCount: post.updateCount,
    displayProfile:
      post.displayProfileId && post.displayUsername && post.displayName
        ? {
            username: post.displayUsername,
            displayName: post.displayName,
            avatarKey: post.displayAvatarKey,
          }
        : null,
    isMine: post.ownerId === options.viewerAccountId,
    hasPrayed: options.hasPrayed,
  };
}

/** Raw D1 row shape. snake_case, straight from SQLite. */
export interface PostRow {
  id: string;
  type: PostType;
  body: string;
  visibility: PostVisibility;
  status: PostStatus;
  display_profile_id: string | null;
  owner_id: string;
  created_at: number;
  updated_at: number;
  answered_at: number | null;
  version: number;
  prayer_response_count: number;
  comment_count: number;
  update_count: number;
  display_username: string | null;
  display_name: string | null;
  display_avatar_key: string | null;
}

export function toPostRecord(row: PostRow): PostRecord {
  return {
    id: row.id,
    type: row.type,
    body: row.body,
    visibility: row.visibility,
    status: row.status,
    displayProfileId: row.display_profile_id,
    ownerId: row.owner_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    answeredAt: row.answered_at,
    version: row.version,
    prayerResponseCount: row.prayer_response_count,
    commentCount: row.comment_count,
    updateCount: row.update_count,
    displayUsername: row.display_username,
    displayName: row.display_name,
    displayAvatarKey: row.display_avatar_key,
  };
}
