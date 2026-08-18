import SwiftUI

/// Shared components. The full library arrives in Phase 5; these are the pieces the core
/// loop needs, built to the same rules so Phase 5 extends rather than replaces them.

/// Rule 19: every feature needs a designed empty state, not a blank screen.
struct EmptyStateView: View {
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
                Button(action.title, action: action.perform)
                    .font(MiracleFont.interface(.headline))
                    .padding(.horizontal, MiracleSpacing.comfortable)
                    .padding(.vertical, MiracleSpacing.medium)
                    .background(MiracleColor.ink, in: .rect(cornerRadius: MiracleRadius.pill))
                    .foregroundStyle(MiracleColor.canvas)
                    .padding(.top, MiracleSpacing.small)
            }
        }
        .padding(MiracleSpacing.generous)
        .accessibilityElement(children: .contain)
    }
}

/// Rule 19: a failure is a designed state too, and it always offers a way forward.
struct ErrorStateView: View {
    let error: AppError
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: MiracleSpacing.regular) {
            Image(systemName: error.isPending ? "wifi.slash" : "exclamationmark.circle")
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

/// Chooses who can see something, before it is written down.
struct PrivacySelector: View {
    @Binding var visibility: PostVisibility
    @Binding var anonymous: Bool
    var onVisibilityChange: (PostVisibility) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            Text("Who can see this?")
                .font(MiracleFont.interface(.subheadline, weight: .medium))
                .foregroundStyle(MiracleColor.ink)

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

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(MiracleFont.interface(.body))
                                .foregroundStyle(MiracleColor.ink)
                            Text(option.explanation)
                                .font(MiracleFont.interface(.caption))
                                .foregroundStyle(MiracleColor.inkSecondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        // Never colour alone.
                        Image(systemName: visibility == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                visibility == option ? MiracleColor.haloGold : MiracleColor.separator
                            )
                    }
                    .padding(MiracleSpacing.regular)
                    .background(
                        visibility == option
                            ? MiracleColor.dawnRose.opacity(0.25)
                            : MiracleColor.canvasElevated,
                        in: .rect(cornerRadius: MiracleRadius.card)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(visibility == option ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(option.explanation)
            }

            if visibility.allowsAnonymity {
                Toggle(isOn: $anonymous) {
                    VStack(alignment: .leading, spacing: 2) {
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

/// The "I prayed" action.
///
/// Large, unhurried, and never a running score. There is no leaderboard and no ranking
/// (rule 13) — the count exists so someone knows they were not alone, and for nothing else.
struct PrayerButton: View {
    let hasPrayed: Bool
    let count: Int
    let isWorking: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.medium) {
                Image(systemName: hasPrayed ? "hands.and.sparkles.fill" : "hands.and.sparkles")
                Text(hasPrayed ? "You prayed" : "I prayed")
                    .font(MiracleFont.interface(.headline))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.regular)
        }
        .background(
            hasPrayed ? MiracleColor.prayerBlue.opacity(0.18) : MiracleColor.prayerBlue,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(hasPrayed ? MiracleColor.prayerBlue : MiracleColor.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.pill)
                .stroke(hasPrayed ? MiracleColor.prayerBlue : .clear, lineWidth: 1)
        )
        .disabled(isWorking)
        .sensoryFeedback(.success, trigger: hasPrayed)
        .animation(reduceMotion ? nil : MiracleMotion.settle, value: hasPrayed)
        .accessibilityLabel(hasPrayed ? "You prayed for this" : "Pray for this")
        .accessibilityValue(supportDescription)
        .accessibilityHint(hasPrayed ? "Double tap to withdraw" : "Double tap to pray")
    }

    private var supportDescription: String {
        switch count {
        case 0: "Nobody has prayed yet"
        case 1: "1 person has prayed"
        default: "\(count) people have prayed"
        }
    }
}

/// One post in a list.
struct PostCard: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.small) {
            HStack(spacing: MiracleSpacing.small) {
                Image(systemName: post.type.symbol)
                    .font(.footnote)
                    .foregroundStyle(post.type == .miracle ? MiracleColor.haloGold : MiracleColor.sage)

                Text(post.isAnsweredPrayer ? "Answered prayer" : post.type.title)
                    .font(MiracleFont.interface(.caption, weight: .medium))
                    .foregroundStyle(MiracleColor.inkSecondary)

                if post.visibility == .privateOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(MiracleColor.inkSecondary)
                        .accessibilityLabel("Private")
                }
                if post.isAnonymous {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(MiracleColor.inkSecondary)
                        .accessibilityLabel("Shared without your name")
                }

                Spacer()

                Text(post.createdAt, format: .dateTime.month(.abbreviated).day())
                    .font(MiracleFont.interface(.caption))
                    .foregroundStyle(MiracleColor.inkSecondary)
            }

            Text(post.body)
                .font(post.type == .miracle ? MiracleFont.reflective(.body) : MiracleFont.interface(.body))
                .foregroundStyle(MiracleColor.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if post.prayerResponseCount > 0 {
                Text(post.prayerResponseCount == 1
                     ? "1 person prayed"
                     : "\(post.prayerResponseCount) people prayed")
                    .font(MiracleFont.interface(.caption))
                    .foregroundStyle(MiracleColor.prayerBlue)
            }
        }
        .padding(MiracleSpacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.card)
                .stroke(MiracleColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
