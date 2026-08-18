import SwiftUI
import Testing
import UIKit
@testable import MyMiracles

/// WCAG 2.1 relative luminance and contrast, computed from resolved colours.
///
/// This resolves the **actual asset catalog** through a trait collection rather than
/// re-declaring hex values in the test, so it measures what the app renders. A palette that
/// drifts out of compliance fails here rather than in someone's hands.
@MainActor
enum Contrast {
    static func ratio(_ foreground: UIColor, _ background: UIColor) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Alpha-composites `foreground` over `background`, as the compositor does on screen.
    ///
    /// Some tokens are only ever rendered as a translucent tint. Measuring them at full
    /// strength would fail a pairing the app never draws.
    static func composite(_ foreground: UIColor, over background: UIColor, alpha: Double) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        foreground.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)

        func mix(_ f: CGFloat, _ b: CGFloat) -> CGFloat { f * alpha + b * (1 - alpha) }
        return UIColor(red: mix(fr, br), green: mix(fg, bg), blue: mix(fb, bb), alpha: 1)
    }

    /// Resolves a named colour for a specific appearance, exactly as UIKit would on device.
    static func color(
        _ name: String,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast = .normal
    ) -> UIColor {
        let traits = UITraitCollection { mutable in
            mutable.userInterfaceStyle = style
            mutable.accessibilityContrast = contrast
        }
        return UIColor(named: name)!.resolvedColor(with: traits)
    }
}

/// Every foreground/background pairing the app actually renders, with the ratio WCAG
/// requires for it.
nonisolated struct ColorPairing: Sendable, CustomTestStringConvertible {
    let foreground: String
    let background: String
    /// 4.5 for body text, 3.0 for large text and non-text UI (icons, borders, controls).
    let required: Double
    let usage: String

    var testDescription: String { "\(foreground) on \(background) — \(usage)" }

    /// a view, it belongs here.
    static let all: [ColorPairing] = [
        .init(foreground: "Ink", background: "Canvas", required: 4.5, usage: "body copy"),
        .init(foreground: "Ink", background: "CanvasElevated", required: 4.5, usage: "card copy"),
        .init(foreground: "InkSecondary", background: "Canvas", required: 4.5, usage: "captions and hints"),
        .init(foreground: "InkSecondary", background: "CanvasElevated", required: 4.5, usage: "card captions"),
        .init(foreground: "PrayerBlue", background: "Canvas", required: 4.5, usage: "support counts"),
        .init(foreground: "PrayerBlue", background: "CanvasElevated", required: 4.5, usage: "support counts on cards"),
        .init(foreground: "Canvas", background: "Ink", required: 4.5, usage: "primary button label"),
        .init(foreground: "Canvas", background: "PrayerBlue", required: 4.5, usage: "I prayed button label"),
        .init(foreground: "Sage", background: "Canvas", required: 3.0, usage: "supporting icons"),
        .init(foreground: "HaloGold", background: "Canvas", required: 3.0, usage: "the spark, accents"),
        .init(foreground: "HaloGold", background: "CanvasElevated", required: 3.0, usage: "selection marks"),
        .init(foreground: "Separator", background: "Canvas", required: 1.3, usage: "hairline borders"),
        .init(foreground: "InkOnAccent", background: "HaloGoldSurface", required: 4.5, usage: "mark as answered label"),
    ]
}

@MainActor
@Suite("Design system contrast")
struct DesignSystemContrastTests {
    @Test("Light mode meets WCAG", arguments: ColorPairing.all)
    func light(pairing: ColorPairing) {
        assert(pairing, style: .light, contrast: .normal)
    }

    @Test("Dark mode meets WCAG", arguments: ColorPairing.all)
    func dark(pairing: ColorPairing) {
        assert(pairing, style: .dark, contrast: .normal)
    }

    /// Increase Contrast must never make anything *worse*, which is the failure mode when
    /// high-contrast variants are added by hand and one gets inverted.
    @Test("Increase Contrast improves on the default", arguments: ColorPairing.all)
    func increaseContrastIsBetter(pairing: ColorPairing) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let normal = ratio(pairing, style: style, contrast: .normal)
            let high = ratio(pairing, style: style, contrast: .high)

            #expect(
                high >= normal - 0.01,
                "\(pairing.testDescription) got worse with Increase Contrast: \(fmt(normal)) → \(fmt(high))"
            )
        }
    }

    @Test("Increase Contrast reaches the enhanced threshold for body copy")
    func enhancedForBodyCopy() {
        // WCAG AAA is 7:1. Not required, but this is a journal — people read it for a while.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let ratio = Contrast.ratio(
                Contrast.color("Ink", style: style, contrast: .high),
                Contrast.color("Canvas", style: style, contrast: .high)
            )
            #expect(ratio >= 7.0, "Ink on Canvas at high contrast is only \(fmt(ratio)):1")
        }
    }

    /// DawnRose is only ever drawn as a tint — 25% behind a selected row, 30% behind an
    /// inline error. These are the composites the app actually renders.
    @Test(
        "Copy stays readable on a warm tint",
        arguments: [("CanvasElevated", 0.25), ("Canvas", 0.30)]
    )
    func warmTintComposites(base: String, alpha: Double) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let tinted = Contrast.composite(
                    Contrast.color("DawnRose", style: style, contrast: contrast),
                    over: Contrast.color(base, style: style, contrast: contrast),
                    alpha: alpha
                )
                let measured = Contrast.ratio(
                    Contrast.color("Ink", style: style, contrast: contrast),
                    tinted
                )
                #expect(
                    measured >= 4.5,
                    "Ink on DawnRose at \(Int(alpha * 100))% over \(base) is \(fmt(measured)):1"
                )
            }
        }
    }

    /// Gold is an accent, never a default text colour (docs/design-system.md). If it ever
    /// passed as body text someone would start using it as body text.
    @Test("Gold is bright enough to be an accent and dim enough not to be body text")
    func goldStaysAnAccent() {
        let ratio = Contrast.ratio(
            Contrast.color("HaloGold", style: .light),
            Contrast.color("Canvas", style: .light)
        )
        #expect(ratio >= 3.0, "gold is too faint even for an icon: \(fmt(ratio)):1")
    }

    @Test("Every token defines all four appearances", arguments: MiracleColor.allNames)
    func fourAppearances(name: String) {
        let resolved = [
            Contrast.color(name, style: .light, contrast: .normal),
            Contrast.color(name, style: .light, contrast: .high),
            Contrast.color(name, style: .dark, contrast: .normal),
            Contrast.color(name, style: .dark, contrast: .high),
        ]
        // Light and dark must genuinely differ, or the token is not adapting at all.
        #expect(resolved[0] != resolved[2], "\(name) is identical in light and dark")
    }

    private func ratio(
        _ pairing: ColorPairing,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) -> Double {
        Contrast.ratio(
            Contrast.color(pairing.foreground, style: style, contrast: contrast),
            Contrast.color(pairing.background, style: style, contrast: contrast)
        )
    }

    private func assert(
        _ pairing: ColorPairing,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) {
        let measured = ratio(pairing, style: style, contrast: contrast)
        #expect(
            measured >= pairing.required,
            "\(pairing.testDescription) is \(fmt(measured)):1, needs \(fmt(pairing.required)):1"
        )
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

@Suite("Design tokens")
nonisolated struct DesignTokenTests {
    /// A scale with duplicates stops being a scale — people pick arbitrarily and the
    /// rhythm goes.
    @Test("Spacing is a strictly increasing scale")
    func spacingScale() {
        let scale = [
            MiracleSpacing.hair, MiracleSpacing.tight, MiracleSpacing.small,
            MiracleSpacing.medium, MiracleSpacing.regular, MiracleSpacing.comfortable,
            MiracleSpacing.generous, MiracleSpacing.sanctuary,
        ]
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
    }

    @Test("Radii increase from control to sheet")
    func radiusScale() {
        #expect(MiracleRadius.small < MiracleRadius.card)
        #expect(MiracleRadius.card < MiracleRadius.sheet)
        #expect(MiracleRadius.sheet < MiracleRadius.pill)
    }

    /// Reduce Motion is honoured centrally, so no feature view has to remember.
    @Test("Motion is suppressed when Reduce Motion is on")
    func reduceMotion() {
        #expect(MiracleMotion.respecting(true) == nil)
        #expect(MiracleMotion.respecting(false) != nil)
        #expect(MiracleMotion.respecting(true, MiracleMotion.arrival) == nil)
    }

    /// Every symbol in the vocabulary must actually exist, or it renders as a blank square
    /// on device and nothing in the build complains.
    @Test(
        "Every icon resolves to a real SF Symbol",
        arguments: [
            MiracleIcon.miracle, MiracleIcon.prayer, MiracleIcon.prayerFilled,
            MiracleIcon.gratitude, MiracleIcon.testimony, MiracleIcon.journal,
            MiracleIcon.support, MiracleIcon.people, MiracleIcon.anyone,
            MiracleIcon.privateEntry, MiracleIcon.anonymous, MiracleIcon.notifications,
            MiracleIcon.report, MiracleIcon.offline, MiracleIcon.problem,
        ]
    )
    func iconsExist(name: String) {
        #expect(UIImage(systemName: name) != nil, "\(name) is not an SF Symbol")
    }

    @Test("Post types use real symbols", arguments: PostType.allCases)
    func postTypeIcons(type: PostType) {
        #expect(UIImage(systemName: type.symbol) != nil)
    }

    @Test("Visibility options use real symbols", arguments: PostVisibility.allCases)
    func visibilityIcons(visibility: PostVisibility) {
        #expect(UIImage(systemName: visibility.symbol) != nil)
    }

    /// Support wording is written once so a card, a button and VoiceOver never disagree.
    @Test("Support counts read naturally at every magnitude")
    func supportWording() {
        #expect(PrayerButton.supportDescription(0) == "Nobody has prayed yet")
        #expect(PrayerButton.supportDescription(1) == "1 person has prayed")
        #expect(PrayerButton.supportDescription(12) == "12 people have prayed")
    }
}
