import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import {
  ACTIONS,
  actOnCase,
  formatTime,
  getCase,
  ModerationError,
  type CaseDetail,
} from '@/lib/moderation';

export const dynamic = 'force-dynamic';

/**
 * One case, and the decision.
 *
 * Shows the content, who reported it and why, everything already decided on this case, and
 * what has been decided about this author before — because a first offence and a fifth
 * deserve different answers.
 */
export default async function CasePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;

  let detail: CaseDetail;
  try {
    detail = await getCase(id);
  } catch (caught) {
    return (
      <div className="card error">
        <strong>
          {caught instanceof ModerationError ? caught.message : 'Could not reach the API.'}
        </strong>
        <p className="body">
          <Link href="/">Back to the queue</Link>
        </p>
      </div>
    );
  }

  /**
   * Records the decision.
   *
   * A server action, so the staff token never reaches the browser. The API requires a
   * reason code regardless — this form is a convenient way to do the right thing, never
   * the thing that makes the rule true.
   */
  async function decide(formData: FormData) {
    'use server';

    const action = String(formData.get('action') ?? '');
    const reasonCode = String(formData.get('reasonCode') ?? '').trim();
    const notes = String(formData.get('notes') ?? '').trim();

    if (!action || reasonCode.length < 2) return;

    await actOnCase(id, action, reasonCode, notes);
    revalidatePath(`/cases/${id}`);
    revalidatePath('/');
  }

  return (
    <>
      <p className="muted">
        <Link href="/">← Queue</Link>
      </p>

      <div className="row">
        <span className={`risk risk-${detail.risk}`}>{detail.risk}</span>
        <span className="grow">
          {detail.subjectType} · {detail.state} · {detail.reportCount}{' '}
          {detail.reportCount === 1 ? 'report' : 'reports'}
        </span>
        <span className="muted">{formatTime(detail.createdAt)}</span>
      </div>

      <h2>The content</h2>
      {detail.subject ? (
        <article className="card">
          <div className="row">
            <span className="grow">
              by <strong>{detail.subject.author ?? 'unknown'}</strong>
              {detail.subject.isAnonymous ? (
                // Anonymous to other users, never to the platform (rule 8). A moderator has
                // to know who wrote something, or nobody can be accountable for it.
                <span className="muted"> · posted anonymously</span>
              ) : null}
            </span>
            <span className="muted">
              {detail.subject.status}
              {detail.subject.visibility ? ` · ${detail.subject.visibility}` : ''}
            </span>
          </div>
          <p className="body">{detail.subject.body ?? '(no text)'}</p>
        </article>
      ) : (
        <div className="card muted">The content is gone. The record of it is not.</div>
      )}

      <h2>Reports</h2>
      {detail.reports.map((report) => (
        <article key={report.id} className="card">
          <div className="row">
            <strong className="grow">{report.category.replace(/_/g, ' ')}</strong>
            <span className="muted">
              {report.reporter ?? 'unknown'} · {formatTime(report.createdAt)}
            </span>
          </div>
          {report.details ? <p className="body">{report.details}</p> : null}
        </article>
      ))}

      {detail.authorHistory.length > 0 ? (
        <>
          <h2>This person before</h2>
          <div className="card warn">
            {detail.authorHistory.map((entry, index) => (
              <div key={index} className="row">
                <strong>{entry.action}</strong>
                <span className="grow muted">
                  {entry.reasonCode} · {entry.subjectType}
                </span>
                <span className="muted">{formatTime(entry.createdAt)}</span>
              </div>
            ))}
          </div>
        </>
      ) : null}

      {detail.actions.length > 0 ? (
        <>
          <h2>Decided so far</h2>
          {detail.actions.map((entry) => (
            <article key={entry.id} className="card">
              <div className="row">
                <strong>{entry.action}</strong>
                <span className="grow muted">{entry.reasonCode}</span>
                <span className="muted">
                  {entry.actor ?? 'unknown'} · {formatTime(entry.createdAt)}
                </span>
              </div>
              {entry.notes ? <p className="body">{entry.notes}</p> : null}
            </article>
          ))}
        </>
      ) : null}

      <h2>Decide</h2>
      <form action={decide} className="card">
        <label htmlFor="action">Action</label>
        <select id="action" name="action" defaultValue="keep" required>
          {ACTIONS.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label} — {option.hint}
            </option>
          ))}
        </select>

        <label htmlFor="reasonCode">Reason code (required)</label>
        <input
          id="reasonCode"
          name="reasonCode"
          required
          minLength={2}
          maxLength={60}
          placeholder="community_guidelines_3"
        />

        <label htmlFor="notes">Notes (optional)</label>
        <textarea id="notes" name="notes" rows={3} maxLength={1000} />

        <button type="submit">Record decision</button>
      </form>

      <p className="muted" style={{ fontSize: '0.85rem' }}>
        Removal hides content and can be undone. Nothing here deletes a row — an action you
        cannot explain later is an action nobody can be held to.
      </p>
    </>
  );
}
