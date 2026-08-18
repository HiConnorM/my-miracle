import { resetJWKSCacheForTesting } from '../src/auth/apple';

/**
 * A stand-in for Apple's signing infrastructure.
 *
 * Generates a real RSA keypair, serves a real JWKS, and mints real RS256 tokens — so the
 * verification path under test is the production one, not a shortcut. Only the key is
 * ours instead of Apple's.
 *
 * Tests run in the same isolate as the Worker, so replacing `globalThis.fetch` also
 * intercepts the Worker's outbound call to `appleid.apple.com`. `SELF.fetch` is a separate
 * Fetcher and is unaffected, which is what keeps request dispatch real.
 */

export interface AppleFixture {
  kid: string;
  mint(claims?: Partial<AppleClaims>): Promise<string>;
  install(): void;
  uninstall(): void;
}

export interface AppleClaims {
  iss: string;
  aud: string;
  sub: string;
  exp: number;
  iat: number;
  nonce?: string;
  email?: string;
  is_private_email?: boolean | string;
}

export const TEST_CLIENT_ID = 'com.mymiracles.MyMiracles.dev';

export async function createAppleFixture(): Promise<AppleFixture> {
  const kid = 'test-apple-key-1';

  // `generateKey` is typed as returning a key *or* a pair; for RSA it is always a pair.
  const keyPair = (await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([0x01, 0x00, 0x01]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;

  const publicJwk = (await crypto.subtle.exportKey('jwk', keyPair.publicKey)) as JsonWebKey;
  const jwks = {
    keys: [{ kty: 'RSA', kid, use: 'sig', alg: 'RS256', n: publicJwk.n, e: publicJwk.e }],
  };

  const realFetch = globalThis.fetch;

  async function mint(overrides: Partial<AppleClaims> = {}): Promise<string> {
    const issuedAt = Math.floor(Date.now() / 1000);
    const claims: AppleClaims = {
      iss: 'https://appleid.apple.com',
      aud: TEST_CLIENT_ID,
      sub: '000123.abcdef.0001',
      iat: issuedAt,
      exp: issuedAt + 600,
      ...overrides,
    };

    const header = base64url(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT' }));
    const payload = base64url(JSON.stringify(claims));
    const signature = await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      keyPair.privateKey,
      new TextEncoder().encode(`${header}.${payload}`),
    );

    return `${header}.${payload}.${bytesToBase64URL(new Uint8Array(signature))}`;
  }

  return {
    kid,
    mint,
    install() {
      resetJWKSCacheForTesting();
      globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
        if (url.startsWith('https://appleid.apple.com/auth/keys')) {
          return new Response(JSON.stringify(jwks), {
            headers: { 'content-type': 'application/json' },
          });
        }
        return realFetch(input as RequestInfo, init);
      }) as typeof globalThis.fetch;
    },
    uninstall() {
      globalThis.fetch = realFetch;
      resetJWKSCacheForTesting();
    },
  };
}

/** Simulates Apple being unreachable, to prove sign-in fails closed. */
export function installFailingJWKS(): () => void {
  const realFetch = globalThis.fetch;
  resetJWKSCacheForTesting();

  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url.startsWith('https://appleid.apple.com/auth/keys')) {
      return new Response('upstream error', { status: 503 });
    }
    return realFetch(input as RequestInfo, init);
  }) as typeof globalThis.fetch;

  return () => {
    globalThis.fetch = realFetch;
    resetJWKSCacheForTesting();
  };
}

function base64url(value: string): string {
  return bytesToBase64URL(new TextEncoder().encode(value));
}

function bytesToBase64URL(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
