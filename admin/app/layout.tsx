import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'My Miracles — moderation',
  // Never indexed. This is an internal tool over other people's private lives.
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <main>
          <h1>Moderation</h1>
          <p className="muted">
            Every decision here is recorded with your name, a reason and both states.
            Nothing on this console deletes anything.
          </p>
          {children}
        </main>
      </body>
    </html>
  );
}
