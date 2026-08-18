import SwiftUI

/// Shown when the build cannot be configured.
///
/// This is a developer-facing screen: it only ever appears on a build whose
/// `Config/Secrets.xcconfig` is missing or wrong. It fails loudly and says exactly what
/// to do, which is much safer than defaulting to some other environment's credentials.
struct ConfigurationErrorView: View {
    let error: AppConfiguration.LoadError

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            VStack(spacing: MiracleSpacing.regular) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(MiracleColor.haloGold)
                    .accessibilityHidden(true)

                Text("This build isn't configured")
                    .font(MiracleFont.interface(.title3, weight: .semibold))
                    .foregroundStyle(MiracleColor.ink)

                Text(error.localizedDescription)
                    .font(MiracleFont.interface(.callout))
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .multilineTextAlignment(.center)

                Text("cp Config/Secrets.example.xcconfig Config/Secrets.Debug.xcconfig")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MiracleColor.ink)
                    .padding(MiracleSpacing.medium)
                    .background(
                        MiracleColor.canvasElevated,
                        in: .rect(cornerRadius: MiracleRadius.small)
                    )
                    .textSelection(.enabled)
            }
            .padding(MiracleSpacing.generous)
        }
    }
}

#if DEBUG
#Preview("Missing API URL") {
    ConfigurationErrorView(error: .missingValue(.apiBaseURL))
}

#Preview("Plaintext in production") {
    ConfigurationErrorView(error: .insecureTransport("http://api.example.com"))
}

#Preview("Credential in the bundle") {
    ConfigurationErrorView(error: .embeddedCredential("MMSessionSecret"))
}
#endif
