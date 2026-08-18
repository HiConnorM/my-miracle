# My Miracles — Design System

## Direction: warm sacred minimalism

Emotionally closer to a beautiful paper journal, candlelight, morning light and quiet
human photography than to a broadcast, a finance dashboard, or a social network.

The app should feel: peaceful · hopeful · deeply human · premium · modern · subtly
spiritual · native to iOS.

It should **not** feel: prosperity gospel · televangelist · church PowerPoint · cheesy
religious stock art · fintech · generic SaaS · Instagram clone.

| Attribute | Should feel | Should not feel |
|---|---|---|
| Spiritual | Reverent, hopeful, sincere | Preachy, denominationally coercive |
| Social | Caring, intimate, reciprocal | Influencer-oriented |
| Emotional | Warm, calm, safe | Manipulative, artificially euphoric |
| Premium | Editorial, intentional | Luxury/wealth signaling |
| Modern | Native iOS, tactile, elegant | Generic SaaS cards everywhere |
| Religious | Prayer is completely normal | Theology forced on every user |
| Inclusive | The user defines their miracle | Religion visually erased |

## Palette

| Token | Hex | Primary use |
|---|---:|---|
| Canvas | `#F8F6F1` | Main warm off-white background |
| Ink | `#1E2932` | Body copy, navigation, high contrast |
| Sage | `#7D9487` | Gratitude, grounding, secondary actions |
| Halo Gold | `#C9A45D` | Miracles, answered moments, brand spark |
| Dawn Rose | `#D9B8AE` | Human warmth, selected backgrounds |
| Prayer Blue | `#6F8797` | Prayer state and prayer actions |

Usage discipline:

- **Gold is an accent, not a default text color.** Gold = a special moment.
- **Prayer Blue = prayer.** Sage = calm and support. The primary UI is mostly neutral.
- Never rely on color alone to carry meaning.
- These hexes are a starting point, not automatically accessible. Verify contrast in
  light and dark, at Increase Contrast, before shipping a screen.

Feature views reference **semantic dynamic colors**, never raw hex.

## Typography

Apple system typography for nearly everything. System `.serif` selectively for miracle
titles, journal years and reflective passages — this preserves Dynamic Type behavior and
keeps a sensitive journal from reading like a marketing site.

## Iconography

A restrained vocabulary: spark/star, hands/support, heart, book/journal, bell,
person/group, lock, shield. SF Symbols wherever possible.

The app mark is a **four-point spark inside a subtle halo**, not a cross. Christian users
do not read it as hostile to faith, and it stays open to other traditions.

## Imagery

Real, intimate, documentary photographs: kitchen tables, sunlight through windows,
holding hands, hospital waiting rooms, a child arriving home, a repaired relationship, a
job letter, a front porch, an ordinary beautiful day.

Avoid: stock clasped hands, prosperity/wealth symbolism, giant worship stages, generic
celestial AI imagery.

The visual claim is: **miracles happen in ordinary life.**

## Token categories

Semantic tokens are required for: colors · typography · spacing · radii · shadows ·
materials · motion · haptics · icons.

## Components

`MiracleCard` · `PrayerCard` · `JournalEntryCard` · `PrimaryButton` · `PrayerButton` ·
`PrivacySelector` · `ProfileAvatar` · `EmptyState` · `LoadingState` · `ErrorState` ·
`SectionHeader` · `CelebrationMoment`

Every component ships with SwiftUI previews covering light, dark, and large Dynamic Type.

## Accessibility — required, not optional (rule 15)

- Dynamic Type through the largest accessibility sizes; no fixed-height text containers.
- VoiceOver labels, values, hints and grouping on every interactive element.
- Reduce Motion honored — `CelebrationMoment` must have a still variant.
- Increase Contrast honored.
- Sufficient contrast verified, not assumed.
- Haptics are subtle and never the sole feedback for an action.

## Screen intent

| Screen | Critical decision |
|---|---|
| Home | Gratitude plus one human prayer need. Not an endless algorithmic feed. |
| Create | Miracle / Prayer / Gratitude in one composer; privacy chosen before posting |
| Prayer detail | Large **I prayed** action — a meaningful response, not a heart count |
| Miracle detail | Visible link to the originating prayer; the story has a beginning and a resolution |
| Journal | Chronological personal archive — the durable value if social usage fades |
| Notifications | Grouped signals: "12 people prayed today", not twelve interruptions |
| Subscription | Premium utility clearly separated from spiritual access |
| Moderation | Risk-ranked operational queue |

No public follower counts at launch. No prayer leaderboard. Miracle counts are memory,
never spiritual score.
