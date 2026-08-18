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
        case .signedIn(let profile):
            SignedInPlaceholder(profile: profile)
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

/// Stands in for Home until Phase 6.
///
/// Kept intentionally bare: the point of Phase 3 is that the door works, not what is behind
/// it. The sign-out and delete controls are here because Apple requires account deletion to
/// be reachable from inside the app, and it should be testable from the first build that
/// has accounts at all.
struct SignedInPlaceholder: View {
    @Environment(AuthenticationModel.self) private var model
    let profile: ProfileResponse

    @State private var isConfirmingDeletion = false

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            VStack(spacing: MiracleSpacing.comfortable) {
                Spacer()

                Image(systemName: "sparkle")
                    .font(.system(size: 44))
                    .foregroundStyle(MiracleColor.haloGold)
                    .accessibilityHidden(true)

                Text("Welcome, \(profile.displayName)")
                    .font(MiracleFont.reflective(.title))
                    .foregroundStyle(MiracleColor.ink)

                Text("@\(profile.username)")
                    .font(MiracleFont.interface(.subheadline))
                    .foregroundStyle(MiracleColor.inkSecondary)

                Text("Your journal begins in Phase 6.")
                    .font(MiracleFont.interface(.footnote))
                    .foregroundStyle(MiracleColor.inkSecondary)

                Spacer()

                VStack(spacing: MiracleSpacing.medium) {
                    Button("Sign out") {
                        Task { await model.signOut() }
                    }
                    .font(MiracleFont.interface(.body))
                    .foregroundStyle(MiracleColor.ink)

                    Button("Delete account", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                    .font(MiracleFont.interface(.footnote))
                }
            }
            .padding(MiracleSpacing.generous)
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete my account", role: .destructive) {
                Task { _ = await model.requestAccountDeletion() }
            }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("Everything you have recorded will be erased after seven days. You can cancel by signing back in before then.")
        }
    }
}

#if DEBUG
#Preview("Signed in") {
    SignedInPlaceholder(profile: ProfileResponse(username: "connor", displayName: "Connor"))
        .environment(AuthenticationModel.preview())
}

#Preview("Launching") {
    LaunchPlaceholder()
}
#endif
