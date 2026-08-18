import SwiftUI

/// Semantic design tokens for **warm sacred minimalism**.
///
/// The app should feel peaceful, hopeful, deeply human, premium, modern, subtly spiritual
/// and native to iOS. It should not feel like prosperity gospel, a televangelist, a church
/// PowerPoint, cheesy religious stock art, fintech, generic SaaS, or an Instagram clone.
///
/// Feature views reference these tokens and never raw hex. Every colour is defined in
/// `Assets.xcassets` with four appearances — light, light high-contrast, dark, dark
/// high-contrast — so the app adapts without a single `colorScheme` branch in feature code,
/// and Increase Contrast is honoured for free.
///
/// The palette's contrast is **verified, not assumed**: `DesignSystemContrastTests`
/// resolves these exact assets and computes WCAG ratios for every pairing the app actually
/// renders. See `docs/design-system.md`.
nonisolated enum MiracleColor {
    /// Main warm off-white background.
    static let canvas = Color("Canvas", bundle: .main)
    /// Raised surfaces — cards, sheets.
    static let canvasElevated = Color("CanvasElevated", bundle: .main)
    /// Body copy, navigation, high contrast.
    static let ink = Color("Ink", bundle: .main)
    /// Supporting copy. Verified for body-text contrast, so it is safe at caption size.
    static let inkSecondary = Color("InkSecondary", bundle: .main)
    /// Gratitude, grounding, secondary actions.
    static let sage = Color("Sage", bundle: .main)
    /// Miracles and answered moments. **An accent, never a default text colour.**
    ///
    /// Tuned to read as an icon against the canvas, which makes it too dark to sit behind
    /// text — use ``haloGoldSurface`` for a fill.
    static let haloGold = Color("HaloGold", bundle: .main)
    /// A gold light enough to sit behind ``inkOnAccent`` in every appearance.
    static let haloGoldSurface = Color("HaloGoldSurface", bundle: .main)
    /// Fixed dark ink for text on a tint that never inverts.
    ///
    /// Deliberately does **not** adapt. `haloGoldSurface` and `dawnRose` are light in both
    /// light and dark mode, so an adaptive ink would turn white on gold and vanish — which
    /// is exactly the bug the contrast suite caught on the "Mark as answered" button.
    static let inkOnAccent = Color("InkOnAccent", bundle: .main)
    /// Human warmth, selected backgrounds. A tint, never a text colour.
    static let dawnRose = Color("DawnRose", bundle: .main)
    /// Prayer state and prayer actions.
    static let prayerBlue = Color("PrayerBlue", bundle: .main)
    static let separator = Color("Separator", bundle: .main)

    /// Every named token, for the contrast suite to sweep.
    static let allNames = [
        "Canvas", "CanvasElevated", "Ink", "InkSecondary", "Sage",
        "HaloGold", "HaloGoldSurface", "DawnRose", "PrayerBlue", "Separator",
    ]
}

nonisolated enum MiracleSpacing {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let comfortable: CGFloat = 24
    static let generous: CGFloat = 32
    static let sanctuary: CGFloat = 48
}

nonisolated enum MiracleRadius {
    static let small: CGFloat = 8
    static let card: CGFloat = 16
    static let sheet: CGFloat = 28
    static let pill: CGFloat = 999
}

/// Apple system typography throughout, with system serif reserved for reflective moments —
/// miracle titles, journal years, remembered passages.
///
/// Every style is a Dynamic Type text style, so nothing here breaks at accessibility sizes.
/// There are no fixed point sizes in feature code.
nonisolated enum MiracleFont {
    /// Serif. For things meant to be read slowly: a miracle, a journal year, an answer.
    static func reflective(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .serif)
    }

    /// The default. Everything a person taps, scans or navigates.
    static func interface(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }

    /// Monospaced, for the few places an exact string matters — a diagnostic, a command.
    static func technical(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced)
    }
}

/// Shadows are almost absent by design. This is paper and daylight, not a floating card UI —
/// depth comes from a hairline border and a change of surface, not from a drop shadow.
nonisolated enum MiracleShadow {
    struct Style: Sendable {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    /// The only elevation in the product: a sheet lifting off the canvas.
    static let lifted = Style(color: .black.opacity(0.08), radius: 18, y: 6)
    /// For a moment that deserves to glow — an answered prayer, and very little else.
    static let halo = Style(color: Color("HaloGold", bundle: .main).opacity(0.28), radius: 24, y: 0)
}

nonisolated extension View {
    func miracleShadow(_ style: MiracleShadow.Style) -> some View {
        shadow(color: style.color, radius: style.radius, y: style.y)
    }
}

/// System materials, used sparingly — over photographs and beneath sheets, where real
/// translucency helps orientation.
nonisolated enum MiracleMaterial {
    static let sheet: Material = .regularMaterial
    static let overlay: Material = .thinMaterial
}

/// Motion is gentle and short. Anything longer than a breath reads as a delay.
///
/// Every animation is gated on Reduce Motion by ``MiracleMotion/respecting(_:)`` — see
/// `CelebrationMoment`, which has a still variant rather than being simply switched off.
nonisolated enum MiracleMotion {
    static let gentle = Animation.easeInOut(duration: 0.28)
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let arrival = Animation.spring(response: 0.55, dampingFraction: 0.75)

    /// Returns `nil` when Reduce Motion is on, which SwiftUI treats as "no animation".
    static func respecting(_ reduceMotion: Bool, _ animation: Animation = gentle) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Haptics are quiet and rare. A prayer is acknowledged; a miracle is celebrated; nothing
/// else vibrates.
///
/// Never the sole feedback for an action (rule 15) — every one of these accompanies a
/// visible change.
nonisolated enum MiracleHaptic {
    /// Someone tapped "I prayed".
    static let prayed: SensoryFeedback = .impact(weight: .light)
    /// A prayer became a miracle.
    static let answered: SensoryFeedback = .success
    /// Something was written down.
    static let saved: SensoryFeedback = .impact(weight: .light, intensity: 0.6)
    static let refused: SensoryFeedback = .warning
}

/// The icon vocabulary, deliberately small.
///
/// A four-point spark inside a halo is the app's mark rather than a cross: a Christian
/// reader does not see it as hostile to faith, and it stays open to someone from another
/// tradition. The user supplies the meaning; the app supplies the container.
nonisolated enum MiracleIcon {
    static let miracle = "sparkle"
    static let prayer = "hands.and.sparkles"
    static let prayerFilled = "hands.and.sparkles.fill"
    static let gratitude = "leaf"
    static let testimony = "text.quote"
    static let journal = "book.closed"
    static let support = "heart"
    static let people = "person.2"
    static let anyone = "globe"
    static let privateEntry = "lock"
    static let anonymous = "eye.slash"
    static let notifications = "bell"
    static let report = "flag"
    static let offline = "wifi.slash"
    static let problem = "exclamationmark.circle"
}
