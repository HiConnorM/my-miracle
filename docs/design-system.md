# My Miracles — Design System

## Direction: warm sacred minimalism

Emotionally closer to a beautiful paper journal, candlelight, morning light and quiet human
photography than to a broadcast, a finance dashboard, or a social network.

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

## Where it lives

| File | Contents |
|---|---|
| [`Core/DesignSystem/MiracleTheme.swift`](../MyMiracles/Core/DesignSystem/MiracleTheme.swift) | Tokens: colour, spacing, radii, typography, shadow, material, motion, haptics, icons |
| [`Core/DesignSystem/MiracleComponents.swift`](../MyMiracles/Core/DesignSystem/MiracleComponents.swift) | The component library, with previews |
| `Resources/Assets.xcassets` | Every colour, in four appearances |
| [`MyMiraclesTests/DesignSystemTests.swift`](../MyMiraclesTests/DesignSystemTests.swift) | Contrast and token verification |

Feature views reference tokens and never raw hex. There are no fixed point sizes in feature
code — every text style is a Dynamic Type style.

## Palette

Each colour ships **four appearances**: light, light high-contrast, dark, dark
high-contrast. The app therefore adapts without a single `colorScheme` branch in feature
code, and Increase Contrast is honoured for free.

| Token | Role |
|---|---|
| `canvas` | Main warm off-white background |
| `canvasElevated` | Raised surfaces — cards, sheets |
| `ink` | Body copy, navigation |
| `inkSecondary` | Supporting copy. Verified for body contrast, so it is safe at caption size |
| `sage` | Gratitude, grounding, supporting icons |
| `haloGold` | Miracles and answered moments. **An accent, never a text colour** |
| `haloGoldSurface` | A gold light enough to sit *behind* text |
| `inkOnAccent` | Fixed dark ink for text on a tint that never inverts |
| `dawnRose` | Human warmth. A tint, never a full-strength background for text |
| `prayerBlue` | Prayer state and prayer actions |
| `separator` | Hairlines |

### Contrast is verified, not assumed

`DesignSystemContrastTests` resolves the **actual asset catalog** through a trait
collection and computes WCAG 2.1 ratios for every pairing the app renders — in light, dark,
and both high-contrast variants. Body text must reach 4.5:1; icons and borders 3:1. A
palette that drifts fails the build.

Two rules came out of that suite catching real bugs:

**A light fill needs a fixed dark label.** `ink` adapts — it is dark on light and light on
dark. Put it on `haloGold`, which is a gold in *both* appearances, and the "Mark as
answered" button measured **1.64:1 in dark mode**. Fills that do not invert take
`inkOnAccent`, which does not invert either. Hence `haloGoldSurface` existing separately
from `haloGold`: the accent is tuned to read as an icon against the canvas, which makes it
too dark to sit behind text.

**Test the composite, not the swatch.** `dawnRose` is only ever drawn at 25–30% over a
surface. Measuring it at full strength failed a pairing the app never draws, so the suite
composites it at the opacities actually used.

## Typography

Apple system typography throughout, with system **serif** reserved for reflective moments —
miracle titles, journal years, an answer. Interface text is the default; monospace appears
only where an exact string matters.

Serif is a signal that something is meant to be read slowly. It is not decoration, and it
never appears on a control.

## Iconography

A deliberately small vocabulary in `MiracleIcon`, all SF Symbols — spark, hands, heart,
book, bell, people, globe, lock, eye-slash, flag. Every one is asserted to resolve, because
a missing symbol renders as a blank square and nothing in the build complains.

The app mark is a **four-point spark inside a halo**, not a cross. A Christian reader does
not see it as hostile to faith, and it stays open to someone from another tradition. The
user supplies the meaning; the app supplies the container.

## Depth and motion

Shadows are almost absent. This is paper and daylight — depth comes from a hairline border
and a change of surface. There are two: `lifted` for a sheet, `halo` for an answered
moment, and very little else.

Motion is gentle and short. Everything routes through `MiracleMotion.respecting(_:)`, which
returns `nil` under Reduce Motion, so no feature view has to remember.

Haptics are quiet and rare: a prayer is acknowledged, a miracle is celebrated, nothing else
vibrates. Never the sole feedback for an action — each accompanies a visible change.

## Components

| Component | Notes |
|---|---|
| `MiracleCard` | The one card. Border and surface, no shadow |
| `PrayerCard` | A prayer awaiting an answer |
| `JournalEntryCard` | One entry; miracles set in serif |
| `PostMetaRow` | Type, privacy, anonymity, date — shared by every card |
| `PrimaryButton` | One per screen. Takes a `foreground` so a light fill can carry dark text |
| `SecondaryButton` | "Not now", "see more" |
| `PrayerButton` | Large, unhurried, never a score |
| `PrivacySelector` | Chosen before writing, not after |
| `ProfileAvatar` | An initial rather than a silhouette; featureless when anonymous |
| `SectionHeader` | Groups without shouting |
| `LoadingState` / `EmptyState` / `ErrorState` / `ErrorNotice` | Rule 19 |
| `CelebrationMoment` | Reduce Motion gets a **still variant**, not a disabled one |

Every component has previews in light, dark and at accessibility text size.

## Accessibility — required, not optional (rule 15)

- **Dynamic Type** to the largest accessibility sizes. Screens that can overflow scroll and
  centre via their container; headlines use `fixedSize(horizontal:vertical:)` so they wrap
  rather than truncate. This was a real bug — the onboarding headline read "never want to
  f…" at accessibility sizes because a `VStack` was competing with its own `Spacer`s.
- **VoiceOver** labels, values and hints on every interactive element. Support counts are
  written once in `PrayerButton.supportDescription` so a card, a button and VoiceOver never
  disagree.
- **Reduce Motion** honoured centrally.
- **Increase Contrast** supported by the asset catalog, and asserted never to make a pairing
  worse.
- **Never colour alone.** Selection carries a checkmark; privacy and anonymity carry
  distinct glyphs with their own labels.

Automated tests cannot see truncation or a bad line break. Check new screens on the
simulator at `accessibility-extra-large`:

```bash
xcrun simctl ui booted content_size accessibility-extra-large
```

## Imagery

Real, intimate, documentary photographs: kitchen tables, sunlight through windows, holding
hands, hospital waiting rooms, a child arriving home, a repaired relationship, a job letter,
a front porch, an ordinary beautiful day.

Avoid: stock clasped hands, prosperity symbolism, giant worship stages, generic celestial AI
imagery.

The visual claim is: **miracles happen in ordinary life.**

## Screen intent

| Screen | Critical decision |
|---|---|
| Home | Gratitude plus one human prayer need. Not an endless algorithmic feed |
| Create | One composer; privacy chosen before posting |
| Prayer detail | Large **I prayed** — a meaningful response, not a heart count |
| Miracle detail | Visible link to the originating prayer; the story has a beginning and a resolution |
| Journal | Chronological personal archive — the durable value if social usage fades |
| Notifications | Grouped: "12 people prayed today", not twelve interruptions |
| Subscription | Premium utility clearly separated from spiritual access |
| Moderation | Risk-ranked operational queue |

No public follower counts at launch. No prayer leaderboard. Miracle counts are memory, never
spiritual score.
