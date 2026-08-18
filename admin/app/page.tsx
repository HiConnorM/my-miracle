import Link from 'next/link';
import { formatTime, listCases, ModerationError, type CaseSummary } from '@/lib/moderation';

export const dynamic = 'force-dynamic';

/**
 * The queue.
 *
 * Ordered by the API, most serious first, so a self-harm report never waits behind a week
 * of spam. This page does no sorting of its own — the ordering is a product decision that
 * belongs in one place.
 */
export default async function QueuePage({
  searchParams,
}: {
  searchParams: Promise<{ state?: string }>;
}) {
  const { state = 'open' } = await searchParams;

  let cases: CaseSummary[] = [];
  let error: string | null = null;

  try {
    cases = (await listCases(state)).items;
  } catch (caught) {
    error = caught instanceof ModerationError ? caught.message : 'Could not reach the API.';
  }

  return (
    <>
      <nav className="tabs">
        {[
          ['open', 'Open'],
          ['triage', 'Triage'],
          ['actioned', 'Actioned'],
          ['dismissed', 'Dismissed'],
          ['all', 'All'],
        ].map(([value, label]) => (
          <Link key={value} href={`/?state=${value}`} data-active={state === value}>
            {label}
          </Link>
        ))}
      </nav>

      {error ? (
        <div className="card error">
          <strong>{error}</strong>
        </div>
      ) : cases.length === 0 ? (
        <div className="card">
          <strong>Nothing waiting.</strong>
          <p className="muted body">
            {state === 'open'
              ? 'No open cases. This is the state you want to be in.'
              : 'No cases in this state.'}
          </p>
        </div>
      ) : (
        cases.map((item) => (
          <Link key={item.id} href={`/cases/${item.id}`} style={{ textDecoration: 'none' }}>
            <article className="card">
              <div className="row">
                <span className={`risk risk-${item.risk}`}>{item.risk}</span>
                <span className="grow">
                  {item.subjectType} · {item.reportCount}{' '}
                  {item.reportCount === 1 ? 'report' : 'reports'}
                </span>
                <span className="muted">{formatTime(item.createdAt)}</span>
              </div>
            </article>
          </Link>
        ))
      )}

      <p className="muted" style={{ marginTop: '2rem', fontSize: '0.85rem' }}>
        Report volume raises priority and nothing else. It is a signal, never a verdict —
        a brigade must not be able to manufacture guilt.
      </p>
    </>
  );
}
