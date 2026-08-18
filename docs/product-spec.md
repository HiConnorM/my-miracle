# My Miracles — Product Specification

## Positioning

> **My Miracles is a private-first record of the moments you never want to forget, with
> an optional community that can pray with you while the story is still unfolding.**

Tagline: *Remember the good. Carry each other.*

We do not compete on volume of professionally produced faith content. Hallow, Glorify,
Pray.com and YouVersion already win that. The defensible asset here is the user's own
accumulating history: requests, the people who carried them, updates, answers, and the
miracles they chose to keep.

Build order of the business: **memory product first, prayer network second, subscription
business third, financial giving only after the first three work.**

## The core loop

```text
Something is happening
        ↓
Ask for prayer
        ↓
People tap "I prayed"
        ↓
Post an update
        ↓
Mark it answered
        ↓
Turn it into a Miracle
        ↓
It enters your permanent Journal
        ↓
People who prayed receive closure
        ↓
Months/years later → "On This Day"
```

Everything in V1 exists to make that loop work and feel emotionally right. If a proposed
feature does not serve this loop, it is not V1.

## The V1 contract (frozen scope)

V1 consists of exactly:

authentication · profiles · private journal · miracle post · prayer request · I prayed ·
updates · answered-prayer conversion · feed · comments/encouragement · follows ·
notifications · reporting · blocking · moderation · account deletion.

**Explicitly not in V1:** DMs. Direct money transfer. AI spiritual adviser. Church
management. Follower or prayer leaderboards. Public popularity metrics.

## Content model

Four post types: `prayer`, `miracle`, `gratitude`, `testimony`.

Three visibilities: `private`, `followers`, `public`.

A post may additionally be displayed **anonymously**. Anonymous means anonymous to other
users, never to the platform — see [database.md](database.md) for how identity is
separated from the client-visible row.

Post lifecycle: `active` → `answered` | `archived` | `removed`.

## Emotional design rules

The requested "dopamine-friendly loops" are interpreted as **rewarding, repeatable
behavior with positive closure** — not compulsive consumption.

| Mechanic | Behavior | Guardrail |
|---|---|---|
| I prayed | One tap, subtle haptic, aggregate count | No leaderboard, no prayer-power ranking |
| Answered conversion | Owner converts prayer to miracle, original preserved | The user defines "answered" |
| One-tap gratitude | A sentence captured in seconds | Private by default |
| On This Day | Resurfaces past miracles | Sensitive memories can be hidden |
| Prayer rhythm | Gentle weekly recognition | Never "you lost your streak" |
| Prayer window | A small daily batch of people to pray for | Finite, not an endless feed |
| Annual recap | "38 moments you chose to remember" | Private unless explicitly shared |

Copy standard: **"You made space for gratitude 4 times this week."** Never
**"0-day streak — start over."**

Finite sessions. After the day's prayer set:

> **You're caught up.**
> Thank you for showing up for someone today.

Implemented in `GET /v1/home`: a batch of five, ordered by **fewest responses first** so
the prayer nobody has carried surfaces before the popular one. Praying removes someone from
the set, so it genuinely empties. "See more" exists but has to be asked for — there is no
automatic next page anywhere in the product.

On This Day resurfaces only the viewer's own miracles, gratitude and *answered* prayers.
Never an open one: bringing back "please pray for my marriage" from three years ago, with
no indication of how it turned out, would be a small cruelty.

Reaction vocabulary stays small: `I prayed` · `Hold this` · `Encourage`. No emoji grid.

## Onboarding

Three meaningful decisions, not a questionnaire.

1. **Remember the moments you never want to forget.** Record miracles, carry prayers,
   and look back on the good.
2. **What would you like to do?** Remember something good · Ask for prayer · Pray for
   others · Keep a private journal
3. **Your journal starts private.** You choose what — if anything — to share.

Then Sign in with Apple or email.

Do **not** request during onboarding: denomination, contacts, notification permission,
location, photos. Notification permission is requested after a meaningful event, e.g.
after the first prayer is created: *"Would you like to know when someone prays for you?"*

## Safety

Apple's UGC guideline requires filtering, reporting, blocking, published contact
information, and a response process. All must ship in V1.

| Risk | V1 safeguard |
|---|---|
| Harassment | Block everywhere; blocked parties removed from each other's feeds |
| Sexual/graphic material | Report taxonomy, automated media/text checks, human review |
| Scam requests | No payment links or cash handles; solicitation rule |
| Doxxing | Warn on phone numbers, addresses, sensitive identifiers before public post |
| Spam | Post/comment rate limits, account-age and risk signals |
| Anonymous abuse | Authenticated backend identity; stricter anonymous throttles |
| Medical claims | Guideline against impersonating professionals or directing treatment |
| Crisis content | Safety resources, priority review path, no claim to replace emergency care |
| Ban evasion | Proportionate device/risk signals, moderator history |
| Brigading | Report-rate anomaly detection; reports never automatically equal guilt |
| Lock-screen exposure | Generic push payloads by default |

Internal service targets (not regulatory promises): **under 1 hour** for credible
immediate-safety reports while staffed, **under 24 hours** for harassment/impersonation,
**under 48 hours** for lower-risk disputes.

Every moderator action records actor, previous state, new state, reason code, timestamp,
evidence reference. Staff never delete rows directly in the database.

## Monetization

Core journal, prayer requests, I prayed, and answered conversion stay free forever.

| Tier | Price | Includes |
|---|---|---|
| Free | $0 | Full core loop, basic media |
| Plus | $7.99/mo · $59.99/yr | Journal organization, advanced search, export/recaps, more media, private Circles |
| Patron | $19.99/mo · $149.99/yr | Plus, supporter recognition, sponsored memberships |

Never: rank paid users above unpaid, boost prayers for money, claim payment improves
prayer outcomes, or restrict prayer functionality by subscription.

## Build order

```text
0. Repository            9.  Moderation
1. Database              10. Notifications
2. Worker authorization  11. Memory & retention loops
3. Authentication        12. Subscriptions
4. Prayer → Miracle      13. Offline synchronization
   vertical slice        14. Analytics
5. Design system         15. Accessibility / performance
6. Home                  16. TestFlight
7. Journal               17. App Store
8. Social
```

Phase 4 is the first TestFlight-worthy milestone. Do not build Circles, widgets or
subscriptions until that loop feels emotionally right on a real iPhone.

## Beta success metrics

Not screen time. Measure: share creating a first private entry; share of prayer creators
receiving ≥1 prayer; share of viewers tapping I prayed; share of prayers receiving an
update; share eventually marked answered; journal week-4 retention; notification disable
rate; reports per 1,000 public posts; moderator reversal rate; public/private ratio;
subscription conversion; crash-free sessions.

## Open items requiring a decision

| Item | Status |
|---|---|
| Name/trademark clearance for "My Miracles" | **Unresolved.** An existing prayer platform (PrayersOutreach) uses "MyMiracles". Treat the name as a working title until cleared. |
| Minimum age policy | Decide with counsel before launch. Do not launch in the Kids Category. |
| Initial geography | United States first. |
| Android | Deferred. Backend stays portable. |
| Direct money ("Send a Miracle") | Deferred until trust operations exist. Stripe Connect when it happens. |
| Nonprofit entity | Only when an actual charitable program exists; not a tax wrapper around the app. |
