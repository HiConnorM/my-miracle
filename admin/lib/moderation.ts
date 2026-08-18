import 'server-only';

/**
 * The console's only route to the Worker.
 *
 * `server-only` makes importing this from a client component a **build error**, which is
 * the guarantee that matters: the staff token is read from the server environment and never
 * crosses to the browser. There is deliberately no `NEXT_PUBLIC_` variable anywhere in this
 * app — that prefix is exactly how a credential ends up in a JavaScript bundle.
 *
 * The console has no database access of its own. It cannot run a query, and it cannot
 * delete a row; it can only call the moderation routes, every one of which writes an audit
 * record. That is the same rule the Worker enforces, held at both ends.
 */

const baseURL = process.env.MM_API_BASE_URL ?? 'http://127.0.0.1:8787';
const staffToken = process.env.MM_STAFF_TOKEN ?? '';

export interface CaseSummary {
  id: string;
  subjectType: 'post' | 'comment' | 'profile';
  subjectId: string;
  risk: 'low' | 'medium' | 'high' | 'critical';
  state: 'open' | 'triage' | 'actioned' | 'dismissed';
  reportCount: number;
  createdAt: number;
  updatedAt: number;
}

export interface CaseDetail extends CaseSummary {
  subject: {
    kind: string;
    body: string | null;
    status: string | null;
    visibility: string | null;
    createdAt: number | null;
    author: string | null;
    isAnonymous: boolean;
  } | null;
  reports: {
    id: string;
    category: string;
    details: string | null;
    reporter: string | null;
    createdAt: number;
  }[];
  actions: {
    id: string;
    action: string;
    reasonCode: string;
    notes: string | null;
    actor: string | null;
    createdAt: number;
  }[];
  authorHistory: {
    action: string;
    reasonCode: string;
    subjectType: string;
    createdAt: number;
  }[];
}

export class ModerationError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  if (!staffToken) {
    throw new ModerationError(500, 'MM_STAFF_TOKEN is not set. See admin/README.md.');
  }

  const response = await fetch(`${baseURL}${path}`, {
    ...init,
    headers: {
      ...init.headers,
      Authorization: `Bearer ${staffToken}`,
      accept: 'application/json',
    },
    // The queue is only useful if it is current.
    cache: 'no-store',
  });

  if (!response.ok) {
    // A 404 here means the token is not staff, or the case is gone. The Worker answers 404
    // rather than 403 on purpose, so the console should not pretend to know which.
    throw new ModerationError(
      response.status,
      response.status === 404
        ? 'Not found, or this token has no moderator access.'
        : `The API refused this request (${response.status}).`,
    );
  }

  return (await response.json()) as T;
}

export function listCases(state = 'open'): Promise<{ items: CaseSummary[] }> {
  return call(`/v1/moderation/cases?state=${encodeURIComponent(state)}`);
}

export function getCase(id: string): Promise<CaseDetail> {
  return call(`/v1/moderation/cases/${encodeURIComponent(id)}`);
}

/**
 * Records a decision.
 *
 * A reason code is required by the API, not just by this form — the console is a convenient
 * way to do the right thing, never the thing that makes the rule true.
 */
export function actOnCase(
  id: string,
  action: string,
  reasonCode: string,
  notes?: string,
): Promise<{ action: string; state: string }> {
  return call(`/v1/moderation/cases/${encodeURIComponent(id)}/actions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action, reasonCode, notes: notes || undefined }),
  });
}

export const ACTIONS = [
  { value: 'keep', label: 'Keep', hint: 'No violation. Closes the case.' },
  { value: 'warn', label: 'Warn', hint: 'Records a warning. Content is untouched.' },
  { value: 'remove', label: 'Remove', hint: 'Hides the content. Reversible.' },
  { value: 'restrict', label: 'Restrict', hint: 'Limits the account. Recorded only.' },
  { value: 'suspend', label: 'Suspend', hint: 'Signs the account out and blocks it.' },
  { value: 'reinstate', label: 'Reinstate', hint: 'Undoes a removal or suspension.' },
  { value: 'escalate', label: 'Escalate', hint: 'Moves to triage for a second opinion.' },
] as const;

export function formatTime(epochMilliseconds: number): string {
  return new Date(epochMilliseconds).toISOString().replace('T', ' ').slice(0, 16);
}
