import SwiftUI

// MARK: - Surfaces

/// The one card in the product.
///
/// Depth comes from a change of surface and a hairline border, not a drop shadow — this is
/// paper and daylight, not a floating-card UI. `PrayerCard` and `JournalEntryCard` compose
/// this rather than restating it.
struct MiracleCard<Content: View>: View {
    var isHighlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(MiracleSpacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHighlighted ? MiracleColor.dawnRose.opacity(0.25) : MiracleColor.canvasElevated,
                in: .rect(cornerRadius: MiracleRadius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MiracleRadius.card)
                    .stroke(isHighlighted ? .clear : MiracleColor.separator, lineWidth: 1)
            )
    }
}

/// A heading that groups without shouting.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var accessory: (title: String, perform: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MiracleSpacing.hair) {
                Text(title)
                    .font(MiracleFont.interface(.subheadline, weight: .semibold))
                    .foregroundStyle(MiracleColor.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(MiracleColor.inkSecondary)
                }
            }
            Spacer()
            if let accessory {
                Button(accessory.title, action: accessory.perform)
                    .font(MiracleFont.interface(.footnote, weight: .medium))
                    .foregroundStyle(MiracleColor.prayerBlue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Someone's face, or their initial.
///
/// Falls back to an initial rather than a generic silhouette — a person with no photo still
/// gets something that is theirs.
struct ProfileAvatar: View {
    let profile: DisplayProfile?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let profile {
                Text(initial(for: profile))
                    .font(.system(size: size * 0.42, weight: .medium, design: .serif))
                    .foregroundStyle(MiracleColor.ink)
                    .frame(width: size, height: size)
                    .background(MiracleColor.dawnRose.opacity(0.5), in: .circle)
            } else {
                // Anonymous. Deliberately featureless — there is nothing here to identify.
                Image(systemName: MiracleIcon.anonymous)
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .frame(width: size, height: size)
                    .background(MiracleColor.separator.opacity(0.4), in: .circle)
            }
        }
        .accessibilityLabel(profile.map { "\($0.displayName)" } ?? "Shared anonymously")
    }

    private func initial(for profile: DisplayProfile) -> String {
        String(profile.displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

// MARK: - Buttons

/// The main action on a screen. There is only ever one.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = MiracleColor.ink
    /// Must contrast with `tint`. The pairing is verified in `DesignSystemContrastTests`.
    var foreground: Color = MiracleColor.canvas
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.small) {
                if isLoading {
                    ProgressView().tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(isLoading ? "Saving…" : title)
                    .font(MiracleFont.interface(.headline))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.regular)
        }
        .background(
            isEnabled ? tint : MiracleColor.inkSecondary,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(foreground)
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

/// Quieter than primary. For "not now", "see more", "skip".
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.small) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(MiracleFont.interface(.body))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.medium)
        }
        .foregroundStyle(MiracleColor.ink)
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.pill)
                .stroke(MiracleColor.separator, lineWidth: 1)
        )
    }
}

/// "I prayed."
///
/// Large, unhurried, and never a running score. There is no leaderboard and no ranking
/// (rule 13) — the count exists so someone knows they were not alone, and for nothing else.
struct PrayerButton: View {
    let hasPrayed: Bool
    let count: Int
    var isWorking = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.medium) {
                Image(systemName: hasPrayed ? MiracleIcon.prayerFilled : MiracleIcon.prayer)
                Text(hasPrayed ? "You prayed" : "I prayed")
                    .font(MiracleFont.interface(.headline))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.regular)
        }
        .background(
            hasPrayed ? MiracleColor.prayerBlue.opacity(0.16) : MiracleColor.prayerBlue,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(hasPrayed ? MiracleColor.prayerBlue : MiracleColor.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.pill)
                .stroke(hasPrayed ? MiracleColor.prayerBlue : .clear, lineWidth: 1)
        )
        .disabled(isWorking)
        .sensoryFeedback(MiracleHaptic.prayed, trigger: hasPrayed)
        .animation(MiracleMotion.respecting(reduceMotion, MiracleMotion.settle), value: hasPrayed)
        .accessibilityLabel(hasPrayed ? "You prayed for this" : "Pray for this")
        .accessibilityValue(Self.supportDescription(count))
        .accessibilityHint(hasPrayed ? "Double tap to withdraw" : "Double tap to pray")
    }

    /// Also used in body copy, so the wording stays identical wherever support is described.
    nonisolated static func supportDescription(_ count: Int) -> String {
        switch count {
        case 0: "Nobody has prayed yet"
        case 1: "1 person has prayed"
        default: "\(count) people have prayed"
        }
    }
}

// MARK: - Content cards

/// A prayer awaiting an answer.
struct PrayerCard: View {
    let post: Post
    var onPray: (() -> Void)?

    var body: some View {
        MiracleCard {
            VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
                PostMetaRow(post: post)

                Text(post.body)
                    .font(MiracleFont.interface(.body))
                    .foregroundStyle(MiracleColor.ink)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if post.prayerResponseCount > 0 {
                    Text(PrayerButton.supportDescription(post.prayerResponseCount))
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(MiracleColor.prayerBlue)
                }

                if let onPray, post.acceptsPrayer, !post.isMine {
                    PrayerButton(
                        hasPrayed: post.hasPrayed,
                        count: post.prayerResponseCount,
                        action: onPray
                    )
                }
            }
        }
    }
}

/// One entry in the journal. Miracles are set in serif — they are meant to be read slowly.
struct JournalEntryCard: View {
    let post: Post

    var body: some View {
        MiracleCard {
            VStack(alignment: .leading, spacing: MiracleSpacing.small) {
                PostMetaRow(post: post)

                Text(post.body)
                    .font(post.type == .miracle
                          ? MiracleFont.reflective(.body)
                          : MiracleFont.interface(.body))
                    .foregroundStyle(MiracleColor.ink)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if post.prayerResponseCount > 0 {
                    Text(PrayerButton.supportDescription(post.prayerResponseCount))
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(MiracleColor.prayerBlue)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Type, privacy, anonymity and date — the row every card shares.
struct PostMetaRow: View {
    let post: Post

    var body: some View {
        HStack(spacing: MiracleSpacing.small) {
            Image(systemName: post.type.symbol)
                .font(.footnote)
                .foregroundStyle(post.type == .miracle ? MiracleColor.haloGold : MiracleColor.sage)

            Text(post.isAnsweredPrayer ? "Answered prayer" : post.type.title)
                .font(MiracleFont.interface(.caption, weight: .medium))
                .foregroundStyle(MiracleColor.inkSecondary)

            // State is never carried by colour alone — each of these is a distinct glyph
            // with its own accessibility label.
            if post.visibility == .privateOnly {
                Image(systemName: MiracleIcon.privateEntry)
                    .font(.caption2)
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .accessibilityLabel("Private")
            }
            if post.isAnonymous {
                Image(systemName: MiracleIcon.anonymous)
                    .font(.caption2)
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .accessibilityLabel("Shared without your name")
            }

            Spacer()

            Text(post.createdAt, format: .dateTime.month(.abbreviated).day())
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
    }
}

// MARK: - The three states every screen must handle (rule 19)

struct LoadingState: View {
    var label: String = "Loading"

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(label)
    }
}

/// An empty result is a designed state, never a blank screen.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: MiracleSpacing.regular) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(MiracleColor.sage)
                .accessibilityHidden(true)

            Text(title)
                .font(MiracleFont.reflective(.title3))
                .foregroundStyle(MiracleColor.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(MiracleFont.interface(.callout))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)

            if let action {
                PrimaryButton(title: action.title, action: action.perform)
                    .padding(.top, MiracleSpacing.small)
            }
        }
        .padding(MiracleSpacing.generous)
        .accessibilityElement(children: .contain)
    }
}

/// A failure is a designed state too, and it always offers a way forward.
///
/// Renders `AppError`'s human copy only. The diagnostic stays redacted and never reaches
/// the screen — a server error body can quote what someone just wrote (rule 7).
struct ErrorState: View {
    let error: AppError
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: MiracleSpacing.regular) {
            Image(systemName: error.isPending ? MiracleIcon.offline : MiracleIcon.problem)
                .font(.system(size: 32))
                .foregroundStyle(MiracleColor.sage)
                .accessibilityHidden(true)

            Text(error.title)
                .font(MiracleFont.interface(.headline))
                .foregroundStyle(MiracleColor.ink)

            Text(error.message)
                .font(MiracleFont.interface(.callout))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)

            if error.isRetryable, let retry {
                Button("Try again", action: retry)
                    .font(MiracleFont.interface(.subheadline, weight: .medium))
                    .foregroundStyle(MiracleColor.prayerBlue)
            }
        }
        .padding(MiracleSpacing.generous)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(error.title). \(error.message)")
    }
}

/// A failure shown inline, beside the thing that failed, rather than taking over a screen.
struct ErrorNotice: View {
    let error: AppError
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.tight) {
            Text(error.title)
                .font(MiracleFont.interface(.subheadline, weight: .semibold))
                .foregroundStyle(MiracleColor.ink)
            Text(error.message)
                .font(MiracleFont.interface(.footnote))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MiracleSpacing.regular)
        .background(MiracleColor.dawnRose.opacity(0.3), in: .rect(cornerRadius: MiracleRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(error.title). \(error.message)")
        .onTapGesture { onDismiss?() }
    }
}

// MARK: - Privacy

/// Chooses who can see something, before it is written down.
struct PrivacySelector: View {
    @Binding var visibility: PostVisibility
    @Binding var anonymous: Bool
    var onVisibilityChange: (PostVisibility) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            SectionHeader(title: "Who can see this?")

            ForEach(PostVisibility.allCases) { option in
                Button {
                    visibility = option
                    onVisibilityChange(option)
                } label: {
                    HStack(spacing: MiracleSpacing.regular) {
                        Image(systemName: option.symbol)
                            .foregroundStyle(
                                visibility == option ? MiracleColor.haloGold : MiracleColor.sage
                            )
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: MiracleSpacing.hair) {
                            Text(option.title)
                                .font(MiracleFont.interface(.body))
                                .foregroundStyle(MiracleColor.ink)
                            Text(option.explanation)
                                .font(MiracleFont.interface(.caption))
                                .foregroundStyle(MiracleColor.inkSecondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Image(systemName: visibility == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                visibility == option ? MiracleColor.haloGold : MiracleColor.separator
                            )
                    }
                }
                .buttonStyle(.plain)
                .padding(MiracleSpacing.regular)
                .background(
                    visibility == option
                        ? MiracleColor.dawnRose.opacity(0.25)
                        : MiracleColor.canvasElevated,
                    in: .rect(cornerRadius: MiracleRadius.card)
                )
                .accessibilityAddTraits(visibility == option ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(option.explanation)
            }

            if visibility.allowsAnonymity {
                Toggle(isOn: $anonymous) {
                    VStack(alignment: .leading, spacing: MiracleSpacing.hair) {
                        Text("Share without my name")
                            .font(MiracleFont.interface(.body))
                            .foregroundStyle(MiracleColor.ink)
                        Text("People can pray, but they won't see who asked.")
                            .font(MiracleFont.interface(.caption))
                            .foregroundStyle(MiracleColor.inkSecondary)
                    }
                }
                .tint(MiracleColor.haloGold)
                .padding(MiracleSpacing.regular)
                .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
            }
        }
    }
}

// MARK: - Celebration

/// The moment a prayer becomes a miracle.
///
/// Warm and brief. **Reduce Motion gets a still variant, not a disabled one** — someone who
/// turns that setting on should still get the moment, just without the movement (rule 15).
struct CelebrationMoment: View {
    let title: String
    let message: String
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false

    var body: some View {
        VStack(spacing: MiracleSpacing.comfortable) {
            Image(systemName: MiracleIcon.miracle)
                .font(.system(size: 64))
                .foregroundStyle(MiracleColor.haloGold)
                .miracleShadow(MiracleShadow.halo)
                .scaleEffect(shouldAnimate && !hasArrived ? 0.6 : 1)
                .opacity(shouldAnimate && !hasArrived ? 0 : 1)
                .accessibilityHidden(true)

            Text(title)
                .font(MiracleFont.reflective(.largeTitle))
                .foregroundStyle(MiracleColor.ink)

            Text(message)
                .font(MiracleFont.reflective(.title3))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)

            if let caption {
                Text(caption)
                    .font(MiracleFont.interface(.footnote))
                    .foregroundStyle(MiracleColor.inkSecondary)
            }
        }
        .sensoryFeedback(MiracleHaptic.answered, trigger: hasArrived)
        .onAppear {
            guard shouldAnimate else { hasArrived = true; return }
            withAnimation(MiracleMotion.arrival) { hasArrived = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    private var shouldAnimate: Bool { !reduceMotion }
}

// MARK: - Previews

#if DEBUG
private struct ComponentGallery: View {
    @State private var visibility = PostVisibility.publicFeed
    @State private var anonymous = false

    var body: some View {
        ScrollView {
            VStack(spacing: MiracleSpacing.comfortable) {
                SectionHeader(title: "Cards", subtitle: "Prayer and journal")

                PrayerCard(post: .fixture(prayerResponseCount: 3, isMine: false), onPray: {})
                JournalEntryCard(post: .fixture(type: .miracle, body: "I got the call. I start on the first."))
                JournalEntryCard(post: .fixture(type: .gratitude, body: "Dad called for no reason at all.", visibility: .privateOnly))
                JournalEntryCard(post: .fixture(type: .prayer, status: .answered, anonymous: true))

                SectionHeader(title: "Buttons")
                PrimaryButton(title: "Record a miracle", systemImage: MiracleIcon.miracle) {}
                PrimaryButton(
                    title: "Mark as answered",
                    tint: MiracleColor.haloGoldSurface,
                    foreground: MiracleColor.inkOnAccent
                ) {}
                PrimaryButton(title: "Saving", isLoading: true) {}
                SecondaryButton(title: "Not now") {}
                PrayerButton(hasPrayed: false, count: 0) {}
                PrayerButton(hasPrayed: true, count: 12) {}

                SectionHeader(title: "People")
                HStack(spacing: MiracleSpacing.regular) {
                    ProfileAvatar(profile: DisplayProfile(username: "connor", displayName: "Connor"))
                    ProfileAvatar(profile: nil)
                    ProfileAvatar(profile: DisplayProfile(username: "gabi", displayName: "Gabi"), size: 56)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SectionHeader(title: "Privacy")
                PrivacySelector(visibility: $visibility, anonymous: $anonymous)
            }
            .padding(MiracleSpacing.regular)
        }
        .background(MiracleColor.canvas)
    }
}

#Preview("Gallery — light") { ComponentGallery() }

#Preview("Gallery — dark") {
    ComponentGallery().preferredColorScheme(.dark)
}

#Preview("Gallery — accessibility size") {
    ComponentGallery().environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("States") {
    VStack(spacing: MiracleSpacing.generous) {
        EmptyState(
            symbol: MiracleIcon.journal,
            title: "Your journal is empty",
            message: "Record something you want to remember.",
            action: (title: "Record a miracle", perform: {})
        )
        ErrorState(error: AppError(kind: .offline), retry: {})
        ErrorNotice(error: AppError(kind: .conflict))
    }
    .background(MiracleColor.canvas)
}

#Preview("Celebration") {
    CelebrationMoment(
        title: "Answered",
        message: "I got the call. I start on the first.",
        caption: "It's in your journal now."
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MiracleColor.canvas)
}
#endif
