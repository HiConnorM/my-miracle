import { unauthenticated } from '../http/responses';
import { sha256Hex } from './tokens';

/**
 * Sign in with Apple identity-token verification.
 *
 * The iOS app obtains an identity token from `ASAuthorizationAppleIDProvider` and sends it
 * here. This Worker is the only thing that decides whether it is genuine — the client's
 * claim to be a particular person is worth nothing until Apple's signature over it checks
 * out.
 *
 * Every step below is load-bearing. Skipping the audience check would let a token minted
 * for *any other app* sign someone in here; skipping `iss` would accept a token from any
 * issuer; verifying the signature but not the expiry would make stolen tokens valid
 * forever.
 */

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';

/** Apple rotates signing keys rarely. An hour keeps the fetch off the hot path. */
const JWKS_TTL_MS = 60 * 60 * 1000;

export interface AppleIdentity {
  /** Apple's stable subject for this user and this app. */
  subject: string;
  email: string | null;
  emailIsPrivateRelay: boolean;
}

interface AppleJWK {
  kty: string;
  kid: string;
  use: string;
  alg: string;
  n: string;
  e: string;
}

interface CachedJWKS {
  keys: AppleJWK[];
  fetchedAt: number;
}

// Module scope persists for the life of the isolate, so this is a per-isolate cache. It is
// only ever a cache: a `kid` miss refetches rather than failing, which is what makes key
// rotation a non-event.
let cache: CachedJWKS | null = null;

export async function verifyAppleIdentityToken(
  token: string,
  options: { clientId: string; nonce?: string | undefined; now?: number },
): Promise<AppleIdentity> {
  const { clientId, nonce, now = Date.now() } = options;

  const parts = token.split('.');
  if (parts.length !== 3) throw unauthenticated('malformed identity token');
  const [rawHeader, rawPayload, rawSignature] = parts as [string, string, string];

  const header = decodeJson<{ kid?: string; alg?: string }>(rawHeader);
  if (!header || header.alg !== 'RS256' || !header.kid) {
    throw unauthenticated('unsupported identity token algorithm');
  }

  const key = await findKey(header.kid);
  if (!key) throw unauthenticated('unknown Apple signing key');

  const verified = await verifySignature(key, `${rawHeader}.${rawPayload}`, rawSignature);
  if (!verified) throw unauthenticated('identity token signature is invalid');

  const claims = decodeJson<{
    iss?: string;
    aud?: string | string[];
    sub?: string;
    exp?: number;
    iat?: number;
    nonce?: string;
    email?: string;
    email_verified?: boolean | string;
    is_private_email?: boolean | string;
  }>(rawPayload);
  if (!claims) throw unauthenticated('identity token payload is not JSON');

  if (claims.iss !== APPLE_ISSUER) throw unauthenticated('unexpected token issuer');

  // Without this, a token Apple minted for a different app would sign someone in here.
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audience.includes(clientId)) throw unauthenticated('token was issued for another app');

  if (typeof claims.exp !== 'number' || claims.exp * 1000 <= now) {
    throw unauthenticated('identity token has expired');
  }
  if (typeof claims.sub !== 'string' || claims.sub.length === 0) {
    throw unauthenticated('identity token has no subject');
  }

  // Replay protection. The client generates a nonce, hands Apple its SHA-256 (hex, matching
  // Apple's own sample code), and sends us the original; Apple echoes the hash back in the
  // token. Both sides must agree on the encoding or every sign-in fails.
  if (nonce !== undefined) {
    const expected = await sha256Hex(nonce);
    if (claims.nonce !== expected) throw unauthenticated('nonce mismatch');
  }

  return {
    subject: claims.sub,
    email: typeof claims.email === 'string' ? claims.email : null,
    emailIsPrivateRelay: isTrue(claims.is_private_email),
  };
}

/** Apple encodes some booleans as the strings "true"/"false". */
function isTrue(value: boolean | string | undefined): boolean {
  return value === true || value === 'true';
}

async function findKey(kid: string): Promise<AppleJWK | null> {
  const fresh = cache && Date.now() - cache.fetchedAt < JWKS_TTL_MS;
  if (fresh) {
    const hit = cache!.keys.find((key) => key.kid === kid);
    if (hit) return hit;
    // A cached-but-unknown kid means Apple rotated. Fall through and refetch rather than
    // rejecting every sign-in until the TTL lapses.
  }

  const keys = await fetchJWKS();
  return keys.find((key) => key.kid === kid) ?? null;
}

async function fetchJWKS(): Promise<AppleJWK[]> {
  const response = await fetch(APPLE_JWKS_URL, {
    headers: { accept: 'application/json' },
  });
  if (!response.ok) {
    // Serve a stale cache rather than locking everyone out during an Apple blip.
    if (cache) return cache.keys;
    throw unauthenticated('could not reach Apple to verify the token');
  }

  const body = (await response.json()) as { keys?: AppleJWK[] };
  const keys = body.keys ?? [];
  cache = { keys, fetchedAt: Date.now() };
  return keys;
}

async function verifySignature(
  jwk: AppleJWK,
  signedData: string,
  signature: string,
): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );

  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    base64URLToBytes(signature),
    new TextEncoder().encode(signedData),
  );
}

/** Exposed for tests, which need to reset the per-isolate cache between cases. */
export function resetJWKSCacheForTesting(): void {
  cache = null;
}

function decodeJson<T>(segment: string): T | null {
  try {
    return JSON.parse(new TextDecoder().decode(base64URLToBytes(segment))) as T;
  } catch {
    return null;
  }
}

function base64URLToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), '='));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
