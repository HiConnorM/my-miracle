# Moderation console

An internal tool for reviewing reports. It reads and writes through the Worker's
`/v1/moderation` routes and has **no database access of its own** — it cannot run a query,
and there is no route it can call that deletes a row.

## Running it

```bash
cp .env.example .env.local
```

```bash
npm install && npm run dev
```

The console then serves on <http://localhost:3100>.

## Issuing a staff token

Two grants are needed, and they are separate on purpose: being **staff** is what opens the
moderation surface, and a **token** is how a server-side console presents that identity.
Revoking either closes the door.

There is deliberately no route that mints moderator credentials — an endpoint that mints
moderator credentials is a target. Tokens are issued directly against the database:

```bash
cd ../workers && npx wrangler d1 execute my-miracles --remote --command "insert into staff (account_id, role, created_at) values ('<account-id>', 'moderator', unixepoch() * 1000)"
```

Then generate a token, store only its hash, and hand the raw value to the deployment:

```bash
node -e "const c=require('crypto');const t='mm_staff_'+c.randomBytes(24).toString('hex');console.log('token:',t);console.log('hash: ',c.createHash('sha256').update(t).digest('hex'))"
```

```bash
cd ../workers && npx wrangler d1 execute my-miracles --remote --command "insert into staff_tokens (id, account_id, label, token_hash, created_at) values (lower(hex(randomblob(16))), '<account-id>', 'production console', '<hash>', unixepoch() * 1000)"
```

The raw token is never stored. If it is lost, revoke the row and issue another:

```bash
cd ../workers && npx wrangler d1 execute my-miracles --remote --command "update staff_tokens set revoked_at = unixepoch() * 1000 where label = 'production console'"
```

## How the credential is kept out of the browser

`lib/moderation.ts` imports `server-only`, so importing it from a client component is a
**build error** rather than a leak. The token is read from `MM_STAFF_TOKEN` — note the
absence of a `NEXT_PUBLIC_` prefix, which is exactly how a secret ends up in a JavaScript
bundle. Decisions are recorded through a server action, so the form posts to the server and
the token never crosses.

Verified by rendering both pages against a live Worker and grepping the HTML and every
client chunk for the token and for internal account ids. Neither appears.

## What it will not do

- **Delete anything.** Removal sets a status and records a reason, so a decision can be
  explained to the person it happened to and undone if it was wrong. `delete from posts` in
  a dashboard leaves no way to answer "who did this, and why?".
- **Act without a reason.** Every decision requires a reason code, enforced by the API and
  not merely by this form.
- **Act anonymously.** Every action records the staff account, including when it arrives
  through a service token.
- **Hide a decision.** "Keep" is recorded too. A case with no action looks exactly like a
  case nobody opened.

## What a moderator sees that users cannot

The real author of an anonymous post. That is the other half of engineering rule 8:
anonymous to other users, **never** to the platform. A platform that cannot identify who
wrote something cannot be accountable for it.

Treat everything on this console as what it is — private writing about illness, marriage,
money and grief, read by staff because somebody raised a concern.

## Deploying

Anywhere that runs Next.js server-side. `MM_STAFF_TOKEN` must be a server environment
variable on that platform, never a build-time constant committed anywhere.
