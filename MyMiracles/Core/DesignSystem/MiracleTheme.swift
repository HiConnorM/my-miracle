import SwiftUI

/// Semantic design tokens for "warm sacred minimalism".
///
/// Phase 0 establishes the token vocabulary and the asset-catalog backing. Phase 5 builds
/// the component library (`MiracleCard`, `PrayerCard`, `PrayerButton`, …) on top of it.
///
/// Feature views reference these tokens, never raw hex (see `docs/design-system.md`).
/// Every color is defined in `Assets.xcassets` with a light and a dark variant so the app
/// adapts without any `colorScheme` branching in feature code.
enum MiracleColor {
    /// Main warm off-white background.
    static let canvas = Color("Canvas", bundle: .main)
    /// Raised surfaces — cards, sheets.
    static let canvasElevated = Color("CanvasElevated", bundle: .main)
    /// Body copy, navigation, high contrast.
    static let ink = Color("Ink", bundle: .main)
    /// Supporting copy. Verify contrast before using at small sizes.
    static let inkSecondary = Color("InkSecondary", bundle: .main)
    /// Gratitude, grounding, secondary actions.
    static let sage = Color("Sage", bundle: .main)
    /// Miracles and answered moments. **An accent, never a default text color.**
    static let haloGold = Color("HaloGold", bundle: .main)
    /// Human warmth, selected backgrounds.
    static let dawnRose = Color("DawnRose", bundle: .main)
    /// Prayer state and prayer actions.
    static let prayerBlue = Color("PrayerBlue", bundle: .main)
    static let separator = Color("Separator", bundle: .main)
}

enum MiracleSpacing {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let comfortable: CGFloat = 24
    static let generous: CGFloat = 32
    static let sanctuary: CGFloat = 48
}

enum MiracleRadius {
    static let small: CGFloat = 8
    static let card: CGFloat = 16
    static let sheet: CGFloat = 28
    static let pill: CGFloat = 999
}

/// Apple system typography throughout, with system serif reserved for reflective moments
/// — miracle titles, journal years, remembered passages. Every style is a Dynamic Type
/// text style, so nothing here breaks at accessibility sizes.
enum MiracleFont {
    static func reflective(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .serif)
    }

    static func interface(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

/// Motion must respect Reduce Motion. Phase 5 wires these into `CelebrationMoment`,
/// which needs a still variant.
enum MiracleMotion {
    static let gentle = Animation.easeInOut(duration: 0.28)
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.86)
}
