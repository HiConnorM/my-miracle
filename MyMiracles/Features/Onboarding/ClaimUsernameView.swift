import SwiftUI

/// The last step of onboarding: choosing a name.
///
/// Reached only when an account exists but has no profile — someone can abandon this and
/// come back later, and the app will ask again rather than leaving a half-built identity.
struct ClaimUsernameView: View {
    @Environment(AuthenticationModel.self) private var model

    @State private var username = ""
    @State private var displayName = ""
    @FocusState private var focus: Field?

    private enum Field { case username, displayName }

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                    header

                    field(
                        label: "Username",
                        hint: "Letters, numbers and underscores. This is how people find you.",
                        text: $username,
                        focus: .username,
                        prompt: "connor"
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    field(
                        label: "Display name",
                        hint: "The name shown on anything you share.",
                        text: $displayName,
                        focus: .displayName,
                        prompt: "Connor"
                    )

                    if let issue = validationIssue, !username.isEmpty {
                        Text(issue)
                            .font(MiracleFont.interface(.footnote))
                            .foregroundStyle(MiracleColor.ink)
                            .accessibilityLabel("Username problem: \(issue)")
                    }

                    if let error = model.error {
                        ErrorNotice(error: error) { model.dismissError() }
                    }

                    submitButton
                }
                .padding(MiracleSpacing.comfortable)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focus = .username }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.small) {
            Text("What should we call you?")
                .font(MiracleFont.reflective(.title))
                .foregroundStyle(MiracleColor.ink)
            Text("You can change this later.")
                .font(MiracleFont.interface(.subheadline))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
    }

    private func field(
        label: String,
        hint: String,
        text: Binding<String>,
        focus field: Field,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.tight) {
            Text(label)
                .font(MiracleFont.interface(.subheadline, weight: .medium))
                .foregroundStyle(MiracleColor.ink)

            TextField(prompt, text: text)
                .font(MiracleFont.interface(.body))
                .padding(MiracleSpacing.regular)
                .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: MiracleRadius.card)
                        .stroke(MiracleColor.separator, lineWidth: 1)
                )
                .focused($focus, equals: field)
                .submitLabel(field == .username ? .next : .done)
                .accessibilityLabel(label)
                .accessibilityHint(hint)

            Text(hint)
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)
                .accessibilityHidden(true)
        }
    }

    private var submitButton: some View {
        Button {
            Task {
                await model.claimProfile(
                    username: username.lowercased(),
                    displayName: displayName.trimmingCharacters(in: .whitespaces)
                )
            }
        } label: {
            Group {
                if model.isWorking {
                    ProgressView().tint(MiracleColor.canvas)
                } else {
                    Text("Continue").font(MiracleFont.interface(.headline))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.regular)
        }
        .background(
            canSubmit ? MiracleColor.ink : MiracleColor.inkSecondary,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(MiracleColor.canvas)
        .disabled(!canSubmit || model.isWorking)
    }

    /// Mirrors the Worker's rules so the common mistakes are caught before a round trip.
    /// The server remains the authority — this is courtesy, not enforcement.
    private var validationIssue: String? {
        UsernameRules.issue(with: username)
    }

    private var canSubmit: Bool {
        validationIssue == nil && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Client-side mirror of the Worker's username rules.
nonisolated enum UsernameRules {
    static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    static func issue(with username: String) -> String? {
        let candidate = username.lowercased()

        if candidate.count < 3 { return "Usernames need at least 3 characters." }
        if candidate.count > 24 { return "Usernames can be at most 24 characters." }
        if !candidate.unicodeScalars.allSatisfy(allowed.contains) {
            return "Use only letters, numbers and underscores."
        }
        return nil
    }
}

#if DEBUG
#Preview("Claim username") {
    ClaimUsernameView()
        .environment(AuthenticationModel.preview())
}

#Preview("Large type") {
    ClaimUsernameView()
        .environment(AuthenticationModel.preview())
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
