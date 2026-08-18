import type { NextConfig } from 'next';

const config: NextConfig = {
  // The moderation console must never be indexed or cached. Every page reads live case
  // data, and a stale queue is a queue somebody stops trusting.
  headers: async () => [
    {
      source: '/:path*',
      headers: [
        { key: 'X-Robots-Tag', value: 'noindex, nofollow' },
        { key: 'Cache-Control', value: 'no-store' },
      ],
    },
  ],
};

export default config;
