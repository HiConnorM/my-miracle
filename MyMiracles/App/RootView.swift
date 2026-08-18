import SwiftUI

/// Placeholder shell for Phase 0.
///
/// It exists to prove the foundation is wired — configuration loaded, logger and
/// analytics resolved, Supabase client constructed, design tokens rendering in light and
/// dark. Phase 3 replaces it with authentication and onboarding; Phase 4 with the
/// prayer → answered → miracle slice. **No product features belong here.**
struct RootView: View {
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            VStack(spacing: MiracleSpacing.comfortable) {
                Image(systemName: "sparkle")
                    .font(.system(size: 44))
                    .foregroundStyle(MiracleColor.haloGold)
                    .accessibilityHidden(true)

                VStack(spacing: MiracleSpacing.small) {
                    Text("My Miracles")
                        .font(MiracleFont.reflective(.largeTitle))
                        .foregroundStyle(MiracleColor.ink)

                    Text("Remember the good. Carry each other.")
                        .font(MiracleFont.interface(.subheadline))
                        .foregroundStyle(MiracleColor.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                if let dependencies {
                    foundationSummary(for: dependencies)
                }
            }
            .padding(MiracleSpacing.generous)
        }
        .onAppear {
            dependencies?.logger.info("root view appeared", category: .app)
        }
    }

    @ViewBuilder
    private func foundationSummary(for dependencies: AppDependencies) -> some View {
        let configuration = dependencies.configuration

        VStack(alignment: .leading, spacing: MiracleSpacing.small) {
            summaryRow(label: "Environment", value: configuration.environment.displayName)
            summaryRow(label: "API host", value: configuration.apiBaseURL.host() ?? "—")
            summaryRow(label: "Embedded credentials", value: "none")
        }
        .font(MiracleFont.interface(.footnote))
        .padding(MiracleSpacing.regular)
        .frame(maxWidth: .infinity)
        .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.card)
                .stroke(MiracleColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Foundation status")
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(MiracleColor.inkSecondary)
            Spacer(minLength: MiracleSpacing.regular)
            Text(value)
                .foregroundStyle(MiracleColor.ink)
        }
    }
}

// Previews use the DEBUG-only preview container, so they compile only in Debug. Staging
// and Release must not carry preview scaffolding into a shipped binary.
#if DEBUG
#Preview("Light") {
    RootView()
        .environment(\.dependencies, .preview())
}

#Preview("Dark") {
    RootView()
        .environment(\.dependencies, .preview())
        .preferredColorScheme(.dark)
}

#Preview("Accessibility size") {
    RootView()
        .environment(\.dependencies, .preview())
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
