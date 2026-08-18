import SwiftUI

/// Your account.
///
/// Deliberately plain. Apple requires account deletion to be reachable from inside the app,
/// and it must not be buried — someone who wants to leave should be able to.
struct SettingsView: View {
    @Environment(AuthenticationModel.self) private var auth
    let profile: ProfileResponse

    @State private var isConfirmingDeletion = false
    @State private var scheduledDeletion: Date?

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MiracleSpacing.comfortable) {
                        identity

                        promises

                        VStack(spacing: MiracleSpacing.medium) {
                            SecondaryButton(title: "Sign out") {
                                Task { await auth.signOut() }
                            }

                            Button("Delete my account", role: .destructive) {
                                isConfirmingDeletion = true
                            }
                            .font(MiracleFont.interface(.footnote))
                        }
                        .padding(.top, MiracleSpacing.regular)
                    }
                    .padding(MiracleSpacing.comfortable)
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete my account", role: .destructive) {
                Task { scheduledDeletion = await auth.requestAccountDeletion() }
            }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("Everything you have recorded will be erased after seven days. You can cancel by signing back in before then.")
        }
    }

    private var identity: some View {
        VStack(spacing: MiracleSpacing.medium) {
            ProfileAvatar(profile: DisplayProfile(
                username: profile.username,
                displayName: profile.displayName
            ), size: 72)

            Text(profile.displayName)
                .font(MiracleFont.reflective(.title2))
                .foregroundStyle(MiracleColor.ink)

            Text("@\(profile.username)")
                .font(MiracleFont.interface(.subheadline))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The promises, written where someone can actually find them.
    private var promises: some View {
        MiracleCard {
            VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
                promise(MiracleIcon.privateEntry, "Your journal is private by default.")
                promise(MiracleIcon.prayer, "We never put prayer behind a paywall.")
                promise(MiracleIcon.anonymous, "Anonymous means anonymous to other people.")
            }
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: MiracleSpacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(MiracleColor.sage)
                .frame(width: 22)
            Text(text)
                .font(MiracleFont.interface(.callout))
                .foregroundStyle(MiracleColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(profile: ProfileResponse(username: "connor", displayName: "Connor"))
        .environment(AuthenticationModel.preview())
}
#endif
