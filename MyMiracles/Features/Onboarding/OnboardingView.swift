import AuthenticationServices
import SwiftUI

/// What someone came here for. Recorded locally to shape the first Home screen (Phase 6).
///
/// Not sent to the server and not part of anyone's profile — it is a hint about what to
/// show first, not a fact about the person.
nonisolated enum OnboardingIntent: String, CaseIterable, Sendable, Identifiable {
    case remember
    case askForPrayer
    case prayForOthers
    case privateJournal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remember: "Remember something good"
        case .askForPrayer: "Ask for prayer"
        case .prayForOthers: "Pray for others"
        case .privateJournal: "Keep a private journal"
        }
    }

    var symbol: String {
        switch self {
        case .remember: "sparkle"
        case .askForPrayer: "hands.and.sparkles"
        case .prayForOthers: "heart"
        case .privateJournal: "book.closed"
        }
    }
}

/// Three meaningful decisions, then sign-in.
///
/// Deliberately does **not** ask for denomination, contacts, notifications, location or
/// photos. Notification permission is requested later, after the first prayer, when the
/// value of saying yes is obvious (docs/product-spec.md).
struct OnboardingView: View {
    @Environment(AuthenticationModel.self) private var model
    @AppStorage("onboarding.intents") private var storedIntents = ""

    @State private var step = 0
    @State private var intents: Set<OnboardingIntent> = []

    private let lastStep = 2

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            VStack(spacing: MiracleSpacing.generous) {
                progress

                // Centred when the content fits, scrollable when it does not.
                //
                // A plain VStack with Spacers truncated the headline at accessibility text
                // sizes — exactly the failure rule 15 exists to prevent. Tying the minimum
                // height to the container keeps the composition centred at ordinary sizes
                // without ever capping growth.
                GeometryReader { proxy in
                    ScrollView {
                        Group {
                            switch step {
                            case 0: welcome
                            case 1: intentPicker
                            default: privacyPromise
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                footer
            }
            .padding(MiracleSpacing.comfortable)
        }
        .animation(MiracleMotion.gentle, value: step)
    }

    private var progress: some View {
        HStack(spacing: MiracleSpacing.small) {
            ForEach(0...lastStep, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? MiracleColor.haloGold : MiracleColor.separator)
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(lastStep + 1)")
    }

    private var welcome: some View {
        VStack(spacing: MiracleSpacing.comfortable) {
            Image(systemName: MiracleIcon.miracle)
                .font(.system(size: 52))
                .foregroundStyle(MiracleColor.haloGold)
                .accessibilityHidden(true)

            Text("Remember the moments you never want to forget.")
                .font(MiracleFont.reflective(.title))
                .foregroundStyle(MiracleColor.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Record miracles, carry prayers, and look back on the good.")
                .font(MiracleFont.interface(.body))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intentPicker: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
            Text("What would you like to do?")
                .font(MiracleFont.reflective(.title2))
                .foregroundStyle(MiracleColor.ink)

            VStack(spacing: MiracleSpacing.medium) {
                ForEach(OnboardingIntent.allCases) { intent in
                    intentRow(intent)
                }
            }

            Text("You can change your mind at any time.")
                .font(MiracleFont.interface(.footnote))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
    }

    private func intentRow(_ intent: OnboardingIntent) -> some View {
        let isSelected = intents.contains(intent)

        return Button {
            if isSelected { intents.remove(intent) } else { intents.insert(intent) }
        } label: {
            HStack(spacing: MiracleSpacing.regular) {
                Image(systemName: intent.symbol)
                    .foregroundStyle(isSelected ? MiracleColor.haloGold : MiracleColor.sage)
                    .frame(width: 28)
                Text(intent.title)
                    .font(MiracleFont.interface(.body))
                    .foregroundStyle(MiracleColor.ink)
                Spacer()
                // Not colour alone: the checkmark carries the state for anyone who cannot
                // distinguish the tint.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? MiracleColor.haloGold : MiracleColor.separator)
            }
            .padding(MiracleSpacing.regular)
            .background(
                isSelected ? MiracleColor.dawnRose.opacity(0.25) : MiracleColor.canvasElevated,
                in: .rect(cornerRadius: MiracleRadius.card)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var privacyPromise: some View {
        VStack(spacing: MiracleSpacing.comfortable) {
            Image(systemName: MiracleIcon.privateEntry)
                .font(.system(size: 44))
                .foregroundStyle(MiracleColor.sage)
                .accessibilityHidden(true)

            Text("Your journal starts private.")
                .font(MiracleFont.reflective(.title))
                .foregroundStyle(MiracleColor.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("You choose what — if anything — to share.")
                .font(MiracleFont.interface(.body))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if step < lastStep {
            PrimaryButton(title: "Continue") { step += 1 }
        } else {
            SignInSection()
                .onAppear {
                    storedIntents = intents.map(\.rawValue).sorted().joined(separator: ",")
                }
        }
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView()
        .environment(AuthenticationModel.preview())
}

#Preview("Dark") {
    OnboardingView()
        .environment(AuthenticationModel.preview())
        .preferredColorScheme(.dark)
}
#endif
