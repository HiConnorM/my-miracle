import Foundation
import SwiftUI

/// The composition root.
///
/// Everything a feature needs is resolved here once, at launch, and handed down the
/// SwiftUI environment. Dependencies are declared as protocol existentials so a feature
/// model can be tested against a fake without touching the network (rule 17, rule 18 — no
/// global singletons, no Redux-style store).
@MainActor
final class AppDependencies {
    let configuration: AppConfiguration
    let logger: any AppLogger
    let analytics: any AnalyticsClient
    /// The only path to the backend. There is no client-side database and no platform
    /// credential — see `docs/architecture.md`.
    let api: any APIClient

    init(
        configuration: AppConfiguration,
        logger: any AppLogger,
        analytics: any AnalyticsClient,
        api: any APIClient
    ) {
        self.configuration = configuration
        self.logger = logger
        self.analytics = analytics
        self.api = api
    }

    /// Wiring for a real build.
    static func live(configuration: AppConfiguration) -> AppDependencies {
        let logger = OSLogAppLogger(environment: configuration.environment)

        // No vendor analytics is wired up yet, and the default outside development stays
        // "emit nothing" — a safe default for a product built on private prayer content.
        let analytics: any AnalyticsClient = configuration.environment == .development
            ? LoggingAnalyticsClient(logger: logger)
            : NoopAnalyticsClient()

        return AppDependencies(
            configuration: configuration,
            logger: logger,
            analytics: analytics,
            api: HTTPAPIClient(
                baseURL: configuration.apiBaseURL,
                // Phase 3 replaces this with the Keychain-backed session store.
                tokens: AnonymousSessionTokenProvider(),
                logger: logger
            )
        )
    }
}

#if DEBUG
extension AppDependencies {
    /// For SwiftUI previews and tests. Points at an unreachable host so a preview can
    /// never write to a real environment.
    static func preview() -> AppDependencies {
        let configuration = AppConfiguration(
            environment: .development,
            apiBaseURL: URL(string: "http://127.0.0.1:8787")!
        )
        return AppDependencies(
            configuration: configuration,
            logger: NoopAppLogger(),
            analytics: NoopAnalyticsClient(),
            api: HTTPAPIClient(
                baseURL: configuration.apiBaseURL,
                tokens: AnonymousSessionTokenProvider(),
                logger: NoopAppLogger()
            )
        )
    }
}
#endif

extension EnvironmentValues {
    /// `nil` until the composition root injects the container, so a view that reaches for
    /// dependencies outside the app hierarchy fails loudly in development instead of
    /// silently constructing a second one.
    @Entry var dependencies: AppDependencies?
}
