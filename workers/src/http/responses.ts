/**
 * HTTP responses and the error vocabulary the iOS client maps onto `AppError`.
 */

export type ApiErrorCode =
  | 'unauthenticated'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'rate_limited'
  | 'invalid'
  | 'server_error';

const STATUS: Record<ApiErrorCode, number> = {
  unauthenticated: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  rate_limited: 429,
  invalid: 422,
  server_error: 500,
};

export class ApiError extends Error {
  constructor(
    readonly code: ApiErrorCode,
    readonly detail?: string,
  ) {
    super(code);
    this.name = 'ApiError';
  }

  get status(): number {
    return STATUS[this.code];
  }

  toResponse(): Response {
    return json({ error: this.code, detail: this.detail }, this.status);
  }
}

/**
 * The viewer may not see this resource.
 *
 * Deliberately `not_found`, never `forbidden`. A 403 confirms the resource exists, which
 * for a private prayer is itself a disclosure — "there is a post with this id and you are
 * not allowed to see it" tells an attacker they found something real. Use
 * {@link forbidden} only when the viewer can already see the thing and is being refused
 * an *action* on it.
 */
export function hidden(detail?: string): ApiError {
  return new ApiError('not_found', detail);
}

export function forbidden(detail?: string): ApiError {
  return new ApiError('forbidden', detail);
}

export function unauthenticated(detail?: string): ApiError {
  return new ApiError('unauthenticated', detail);
}

export function invalid(detail: string): ApiError {
  return new ApiError('invalid', detail);
}

export function conflict(detail?: string): ApiError {
  return new ApiError('conflict', detail);
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204 });
}
