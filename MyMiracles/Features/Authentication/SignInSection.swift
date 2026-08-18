import AuthenticationServices
import SwiftUI

/// The Sign in with Apple control and the copy around it.
///
/// A dumb view (rule 17): it configures the request and forwards the result, and every
/// decision belongs to ``AuthenticationModel``.
struct SignInSection: View {
    @Environment(AuthenticationModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: MiracleSpacing.regular) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(height: 50)
                    .accessibilityLabel("Signing in")
            } else {
                SignInWithAppleButton(.signIn) { request in
                    model.prepare(request: request)
                } onCompletion: { result in
                    Task { await model.handle(result: result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: MiracleRadius.pill))
            }

            if let error = model.error {
                ErrorNotice(error: error) { model.dismissError() }
            }

            Text("We never sell your data, and we never put prayer behind a paywall.")
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

#if DEBUG
#Preview("Sign in") {
    SignInSection()
        .environment(AuthenticationModel.preview())
        .padding()
        .background(MiracleColor.canvas)
}

#Preview("Offline") {
    ErrorNotice(error: AppError(kind: .offline))
        .padding()
        .background(MiracleColor.canvas)
}
#endif
