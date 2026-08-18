import SwiftUI

/// Routes on authentication state.
///
/// `signedInWithoutProfile` is a first-class branch, not an edge case: an account exists
/// the moment Apple verifies, but a username is chosen afterwards. Someone who abandons
/// onboarding lands back here and is asked again.
struct RootView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var model: AuthenticationModel?

    var body: some View {
        Group {
            if let model {
                content(for: model)
                    .environment(model)
            } else {
                LaunchPlaceholder()
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = dependencies.makeAuthenticationModel()
            model = created
            await created.restore()
        }
    }

    @ViewBuilder
    private func content(for model: AuthenticationModel) -> some View {
        switch model.state {
        case .restoring:
            LaunchPlaceholder()
        case .signedOut:
            OnboardingView()
        case .signedInWithoutProfile:
            ClaimUsernameView()
        case .signedIn:
            JournalView()
        }
    }
}

/// Shown while a stored session is being restored. Deliberately the same composition as the
/// launch screen so there is no flash between them.
struct LaunchPlaceholder: View {
    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()
            Image(systemName: "sparkle")
                .font(.system(size: 44))
                .foregroundStyle(MiracleColor.haloGold)
                .accessibilityLabel("My Miracles")
        }
    }
}

#if DEBUG
#Preview("Launching") {
    LaunchPlaceholder()
}
#endif
