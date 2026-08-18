/**
 * Bindings that are not in `wrangler.jsonc` and therefore absent from the generated
 * `worker-configuration.d.ts`.
 *
 * Secrets are set with `wrangler secret put` and never appear in a committed file — but
 * they still need types, so they are declared here by merging into the generated
 * namespace.
 */
declare namespace Cloudflare {
  interface Env {
    /** HMAC key for signing session access tokens. `wrangler secret put SESSION_SIGNING_KEY`. */
    SESSION_SIGNING_KEY: string;
  }
}
